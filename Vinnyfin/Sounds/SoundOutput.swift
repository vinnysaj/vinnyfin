import AVFoundation
import OSLog

/// Plays Sounds' sound, off the main thread: the audio session's calls and the engine's start are
/// round trips to the media server that can block for a while.
///
/// While it plays or is paused, the session is `.playback`, not mixed with other apps, so the sound
/// is the Now Playing app and another app's audio interrupts it. Whenever it lets go, it leaves the
/// session as the video player's engine declares it before its first load (`.playback` for
/// movies), which the engine then keeps, as it does any `.playback` session it finds: so a video
/// that opens finds the session it would have made itself, whichever of the two gets to the
/// session first. Handing over to a video leaves the session active for it; stopping deactivates
/// it first, telling other apps they may carry on. The Mac has no audio session.
actor SoundOutput {
    enum Target: Equatable, Sendable {
        case playing(Sound)
        /// Silent, keeping the session and the sound where it is, so the Lock Screen's play
        /// carries on from it.
        case paused
        /// A video takes the session over.
        case handedOver
        case stopped
    }

    nonisolated static let fadeOutDuration: Duration = .seconds(8)
    nonisolated static let fadeOutSteps = 40
    private nonisolated static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "sounds")

    private var engine: AVAudioEngine?
    private var playing: Sound?
    private var lastRevision = 0
    #if !os(macOS)
    /// The session is in Sounds' category, until it's handed back.
    private var holdsSession = false
    #endif

    /// Brings the output to `target`. Drops the call when a later one has been carried out, and
    /// stops a fade-out that a later call overtakes. `rebuild` builds the engine anew, after a
    /// media services reset or a new output; `fadingOut` lowers a stop over `fadeOutDuration`.
    func apply(_ target: Target, revision: Int, rebuild: Bool = false, fadingOut: Bool = false) async throws {
        guard revision > lastRevision else { return }
        lastRevision = revision
        switch target {
        case .playing(let sound):
            try play(sound, rebuild: rebuild)
        case .paused:
            engine?.pause()
        case .handedOver:
            tearDown()
            try releaseSession(deactivating: false)
        case .stopped:
            if fadingOut {
                try await fadeOut(revision: revision)
                guard revision == lastRevision else { return }
            }
            tearDown()
            try releaseSession(deactivating: true)
        }
    }

    private func play(_ sound: Sound, rebuild: Bool) throws {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        if !holdsSession {
            try session.setCategory(.playback, mode: .default, policy: .default, options: [])
            holdsSession = true
        }
        try session.setActive(true)
        #endif
        if !rebuild, let engine, playing == sound {
            engine.mainMixerNode.outputVolume = 1
            if !engine.isRunning { try engine.start() }
            return
        }
        tearDown()
        let engine = AVAudioEngine()
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: outputRate > 0 ? outputRate : 48_000, channels: 2) else {
            throw SoundOutputError.noFormat
        }
        try Self.attach(Self.source(for: sound, format: format), to: engine, format: format)
        engine.prepare()
        self.engine = engine
        playing = sound
        try engine.start()
        Self.log.info("Playing \(sound.rawValue, privacy: .public) at \(format.sampleRate) Hz")
    }

    /// Puts `source` in `engine`, playing into its main mixer.
    nonisolated static func attach(_ source: AVAudioSourceNode, to engine: AVAudioEngine, format: AVAudioFormat) throws {
        engine.attach(source)
        if #available(tvOS 27, *) {
            try engine.connectNode(source, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(source, to: engine.mainMixerNode, format: format)
        }
    }

    /// The node that makes the sound as it plays. Made outside the actor: its block runs on the
    /// audio thread, and a block made in an isolated context checks for that isolation when it
    /// runs, and crashes there.
    nonisolated static func source(for sound: Sound, format: AVAudioFormat) -> AVAudioSourceNode {
        let synthesizer = SynthesizerState(SoundSynthesizer(sound: sound, sampleRate: format.sampleRate))
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            let frames = Int(frameCount)
            synthesizer.value.render(left: UnsafeMutableBufferPointer(start: left, count: frames),
                                     right: UnsafeMutableBufferPointer(start: right, count: frames))
            return noErr
        }
    }

    /// Lowers the volume to nothing, unless a later call overtakes it.
    private func fadeOut(revision: Int) async throws {
        guard let engine, engine.isRunning else { return }
        let steps = Self.fadeOutSteps
        for step in 1...steps {
            try await Task.sleep(for: Self.fadeOutDuration / steps)
            guard revision == lastRevision, engine === self.engine else { return }
            let left = 1 - Float(step) / Float(steps)
            engine.mainMixerNode.outputVolume = left * left
        }
    }

    private func tearDown() {
        engine?.stop()
        engine = nil
        playing = nil
    }

    /// Leaves the session as the video player declares it: active for a video that takes it
    /// over, or deactivated, telling other apps they may carry on.
    private func releaseSession(deactivating: Bool) throws {
        #if !os(macOS)
        guard holdsSession else { return }
        let session = AVAudioSession.sharedInstance()
        if deactivating { try session.setActive(false, options: .notifyOthersOnDeactivation) }
        try session.setCategory(.playback, mode: .moviePlayback, policy: .default, options: [])
        holdsSession = false
        Self.log.info("Let go of the session: \(deactivating ? "stopped" : "handed over to a video", privacy: .public)")
        #endif
    }
}

/// The synthesizer the source node's block owns, and only it touches, on the audio thread.
nonisolated private final class SynthesizerState {
    var value: SoundSynthesizer

    init(_ value: SoundSynthesizer) {
        self.value = value
    }
}

nonisolated enum SoundOutputError: LocalizedError {
    case noFormat

    var errorDescription: String? {
        switch self {
        case .noFormat: "the audio output gave no format to play in."
        }
    }
}
