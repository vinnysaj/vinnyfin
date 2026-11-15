import AetherEngine
import Foundation

/// How much later than the file times them each title's subtitles show, as the viewer set it in
/// the Audio & Subtitles panel. Kept on this device for the titles timed most recently, by the
/// title's history key, so a title plays with its subtitles in time again, a stream of another
/// version of it included.
nonisolated struct SubtitleOffsets {
    /// Steps of the timing control in a second.
    static let stepsPerSecond = 10.0
    /// One step of the timing control, in seconds.
    static let step = 1 / stepsPerSecond
    /// Further off than this, either way, the subtitles are for another cut of the title.
    static let limit = 60.0
    /// How many titles' timings are kept, the most recently set.
    static let capacity = 200

    private let defaults: UserDefaults
    private static let key = "subtitleOffsets"

    private struct Entry: Codable {
        let title: String
        let offset: Double
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Seconds later than the file times them that `title`'s subtitles show; earlier when negative.
    func offset(for title: String) -> Double {
        entries.last { $0.title == title }?.offset ?? 0
    }

    /// Keeps `offset` for `title`, as the most recently set; zero keeps nothing.
    func set(_ offset: Double, for title: String) {
        var entries = entries.filter { $0.title != title }
        let offset = Self.rounded(offset)
        if offset != 0 { entries.append(Entry(title: title, offset: offset)) }
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    /// `seconds` to the nearest step, within the limit either way, so steps add up exactly.
    static func rounded(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let steps = (min(max(seconds, -limit), limit) * stepsPerSecond).rounded()
        // Dividing a whole number of steps gives the nearest Double to the decimal, as
        // multiplying by `step` doesn't: 3 * 0.1 is 0.30000000000000004.
        return steps == 0 ? 0 : steps / stepsPerSecond
    }

    /// "+0.3 s", "−1.2 s", "0.0 s".
    static func label(_ offset: Double) -> String {
        let sign = offset > 0 ? "+" : offset < 0 ? "\u{2212}" : ""
        return sign + abs(offset).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    /// What VoiceOver says: "In time", "0.3 seconds later", "1.2 seconds earlier".
    static func spoken(_ offset: Double) -> String {
        guard offset != 0 else { return "In time" }
        let amount = abs(offset).formatted(.number.precision(.fractionLength(1)))
        return "\(amount) seconds \(offset > 0 ? "later" : "earlier")"
    }

    private var entries: [Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}

/// The sound tools in the Audio & Subtitles panel, for every playback on this device until
/// they're turned off: the dialogue raised over the rest of the mix, and loud sounds brought
/// down toward quiet ones, through the engine's audio shaping.
nonisolated struct SoundOptions: Equatable, Codable {
    var boostsDialogue = false
    var reducesLoudSounds = false

    /// How far Boost Dialogue raises the dialogue, in dB: clearly louder over the score, short of
    /// a centre channel sounding like a speaker of its own.
    static let dialogueBoost: Double = 6

    /// What the engine shapes the sound with.
    var shaping: AudioShaping {
        AudioShaping(dialogueGainDB: boostsDialogue ? Self.dialogueBoost : 0,
                     compressor: reducesLoudSounds ? .night : nil)
    }

    /// The tools on, by name: "Boost Dialogue", "Boost Dialogue and Reduce Loud Sounds"; nil
    /// with both off.
    var namesOn: String? {
        let on = [boostsDialogue ? "Boost Dialogue" : nil, reducesLoudSounds ? "Reduce Loud Sounds" : nil].compactMap(\.self)
        return on.isEmpty ? nil : on.joined(separator: " and ")
    }

    // Shaping needs decoded sound, so the engine decodes a track it otherwise passes on as made
    // while a tool is on: Dolby Atmos (E-AC-3 with its objects) reaches the receiver as its
    // surround channels alone then.

    /// What the tools cost a track, said under them whether they're on or not, so turning one on
    /// for a film doesn't quietly take the Atmos of every one after it. Nil for a track they cost
    /// nothing.
    static func atmosNote(isAtmos: Bool, channels: Int) -> String? {
        guard isAtmos else { return nil }
        return "While either is on, Dolby Atmos plays as \(bed(channels))"
    }

    /// What the tools on are doing to a track: nil with them off, or for a track they cost nothing.
    func atmosEffect(isAtmos: Bool, channels: Int) -> String? {
        guard isAtmos, let on = namesOn else { return nil }
        return "Without Atmos, as \(Self.bed(channels)), while \(on) \(boostsDialogue && reducesLoudSounds ? "are" : "is") on"
    }

    /// The surround an Atmos track's channels make on their own.
    private static func bed(_ channels: Int) -> String {
        switch channels {
        case 6: "5.1 surround"
        case 8: "7.1 surround"
        default: "surround sound"
        }
    }

    private static let key = "soundOptions"

    static func saved(in defaults: UserDefaults = .standard) -> SoundOptions {
        guard let data = defaults.data(forKey: key) else { return SoundOptions() }
        return (try? JSONDecoder().decode(SoundOptions.self, from: data)) ?? SoundOptions()
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// How loud the player plays, from its keys: up and down a step at a time, and muted. Applies
/// to the playback's own sound, under the system's volume.
nonisolated struct PlayerVolume: Equatable {
    /// From nothing to 1.
    private(set) var level: Float = 1
    private(set) var isMuted = false

    /// As far as a press of the Mac's volume keys.
    static let step: Float = 1 / 16

    init(level: Float = 1) {
        self.level = min(max(level, 0), 1)
    }

    /// What the engine plays at.
    var output: Float { isMuted ? 0 : level }

    /// A step louder or quieter; either unmutes.
    mutating func change(up: Bool) {
        isMuted = false
        let steps = (level / Self.step).rounded() + (up ? 1 : -1)
        level = min(max(steps * Self.step, 0), 1)
    }

    mutating func toggleMute() {
        isMuted.toggle()
    }

    /// To `level`, as a slider sets it; unmutes.
    mutating func set(_ level: Float) {
        isMuted = false
        self.level = min(max(level, 0), 1)
    }

    /// The speaker it shows: struck through while nothing plays, else with as many waves lit as
    /// the level (`Image(systemName:variableValue:)`).
    var symbol: String {
        output == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }
}
