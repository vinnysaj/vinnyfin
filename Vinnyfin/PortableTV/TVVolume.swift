#if os(macOS)
import AudioToolbox
import CoreAudio
import Observation

/// Portable TV's volume, which the remote's buttons turn up, down and off. Where the Mac's sound
/// goes out through something the Mac sets the volume of, as its speakers, it's the Mac's own. A
/// TV on HDMI keeps its volume to itself and gives the Mac none to set, and there it's how loud
/// the app itself plays, the player and YouTube.
@Observable
final class TVVolume {
    /// From nothing to 1, as the last press left it.
    private(set) var level: Float = 1
    private(set) var isMuted = false
    /// Counts the presses, for each of which the TV shows the volume.
    private(set) var presses = 0

    /// How loud the app plays, where the Mac has no volume to set; in full where it has.
    @ObservationIgnored private var own: (level: Float, isMuted: Bool) = (1, false)
    /// Plays the app's own sound this loud, from nothing to 1.
    @ObservationIgnored private let playAt: (Float) -> Void

    /// As far as a press of the Mac's volume keys.
    private static let step: Float = 1 / 16

    init(playAt: @escaping (Float) -> Void) {
        self.playAt = playAt
    }

    /// A step up or down, which turns the sound back on.
    func turn(up: Bool) {
        let level = current.level + (up ? Self.step : -Self.step)
        set(level: min(1, max(0, level)), isMuted: false)
    }

    func toggleMute() {
        let current = current
        set(level: current.level, isMuted: !current.isMuted)
    }

    /// The app plays in full again, as Portable TV turns off. The Mac's volume stays as set.
    func letGo() {
        setOwn(level: 1, isMuted: false)
    }

    private var current: (level: Float, isMuted: Bool) {
        if let output = OutputDevice.current, let level = output.level { return (level, output.isMuted) }
        return own
    }

    private func set(level: Float, isMuted: Bool) {
        if let output = OutputDevice.current, output.level != nil {
            output.set(level: level)
            output.set(isMuted: isMuted)
            // In case the sound went through the TV until now.
            setOwn(level: 1, isMuted: false)
        } else {
            setOwn(level: level, isMuted: isMuted)
        }
        (self.level, self.isMuted) = current
        presses += 1
    }

    private func setOwn(level: Float, isMuted: Bool) {
        guard own != (level, isMuted) else { return }
        own = (level, isMuted)
        playAt(isMuted ? 0 : level)
    }
}

/// What the Mac's sound goes out through, and its volume where the Mac sets it.
private struct OutputDevice {
    let id: AudioDeviceID

    static var current: OutputDevice? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? OutputDevice(id: id) : nil
    }

    /// Nil where the device has no volume for the Mac to set.
    var level: Float? {
        isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume) ? value(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(0)) : nil
    }

    var isMuted: Bool {
        value(kAudioDevicePropertyMute, UInt32(0)) == 1
    }

    func set(level: Float) {
        set(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, to: Float32(level))
    }

    func set(isMuted: Bool) {
        guard isSettable(kAudioDevicePropertyMute) else { return }
        set(kAudioDevicePropertyMute, to: UInt32(isMuted ? 1 : 0))
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func isSettable(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(id, &address) && AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    private func value<Value>(_ selector: AudioObjectPropertySelector, _ empty: Value) -> Value? {
        var address = address(selector)
        var value = empty
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func set<Value>(_ selector: AudioObjectPropertySelector, to value: Value) {
        var address = address(selector)
        var value = value
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value)
    }
}
#endif
