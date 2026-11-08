import AVFoundation
import Foundation
import Testing
@testable import vinnyfin

/// Renders `seconds` of `sound` at 48 kHz, after the fade-in.
private func render(_ sound: Sound, seconds: Double, seed: UInt64 = 7) -> (left: [Float], right: [Float]) {
    let rate = 48_000.0
    var synthesizer = SoundSynthesizer(sound: sound, sampleRate: rate, seed: seed)
    let skipped = Int(SoundSynthesizer.fadeInDuration * rate)
    var left = [Float](repeating: 0, count: skipped + Int(seconds * rate))
    var right = left
    left.withUnsafeMutableBufferPointer { left in
        right.withUnsafeMutableBufferPointer { right in synthesizer.render(left: left, right: right) }
    }
    return (Array(left[skipped...]), Array(right[skipped...]))
}

/// Integrated loudness in LUFS, by ITU-R BS.1770's K-weighting at 48 kHz, without gating: these
/// sounds have no silences to gate out.
private func loudness(_ left: [Float], _ right: [Float]) -> Double {
    struct Biquad {
        let b: (Double, Double, Double)
        let a: (Double, Double)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func run(_ x: Double) -> Double {
            let y = b.0 * x + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return y
        }
    }
    func weighted(_ samples: [Float]) -> Double {
        var shelf = Biquad(b: (1.53512485958697, -2.69169618940638, 1.19839281085285), a: (-1.69065929318241, 0.73248077421585))
        var highPass = Biquad(b: (1, -2, 1), a: (-1.99004745483398, 0.99007225036621))
        return samples.reduce(0) { total, sample in
            let y = highPass.run(shelf.run(Double(sample)))
            return total + y * y
        }
    }
    return -0.691 + 10 * log10((weighted(left) + weighted(right)) / Double(left.count))
}

struct SoundSynthesizerTests {
    @Test(arguments: Sound.allCases)
    func staysInRangeAndMakesSound(_ sound: Sound) {
        let (left, right) = render(sound, seconds: 5)
        #expect(left.allSatisfy { $0.isFinite && abs($0) <= SoundSynthesizer.ceiling })
        #expect(right.allSatisfy { $0.isFinite && abs($0) <= SoundSynthesizer.ceiling })
        #expect(left.contains { abs($0) > 0.01 })
    }

    /// Every sound is about as loud as the others, so changing sound doesn't change the volume.
    /// The waves need long enough for several of them.
    @Test(arguments: Sound.allCases)
    func isAsLoudAsTheOthers(_ sound: Sound) {
        let (left, right) = render(sound, seconds: sound == .ocean ? 60 : 10)
        #expect(abs(loudness(left, right) - SoundSynthesizer.loudness) < 1.5, "\(sound.name)")
    }

    /// Each channel has noise of its own, so the sound is wide.
    @Test(arguments: Sound.allCases)
    func channelsDiffer(_ sound: Sound) {
        let (left, right) = render(sound, seconds: 2)
        let correlation = zip(left, right).reduce(0.0) { $0 + Double($1.0 * $1.1) }
            / (left.reduce(0.0) { $0 + Double($1 * $1) } * right.reduce(0.0) { $0 + Double($1 * $1) }).squareRoot()
        #expect(abs(correlation) < 0.2, "\(sound.name)")
    }

    @Test func fadesInRatherThanClicking() {
        var synthesizer = SoundSynthesizer(sound: .whiteNoise, sampleRate: 48_000, seed: 3)
        var left = [Float](repeating: 0, count: 480)
        var right = left
        left.withUnsafeMutableBufferPointer { left in
            right.withUnsafeMutableBufferPointer { right in synthesizer.render(left: left, right: right) }
        }
        // The first 10 ms are under 1% of the way up.
        #expect(left.allSatisfy { abs($0) < SoundSynthesizer.gain(for: .whiteNoise) * 0.01 })
    }

    @Test func theSameSeedMakesTheSameSound() {
        #expect(render(.rain, seconds: 1, seed: 11).left == render(.rain, seconds: 1, seed: 11).left)
        #expect(render(.rain, seconds: 1, seed: 11).left != render(.rain, seconds: 1, seed: 12).left)
    }

    @Test func goesRoundTheSoundsBothWays() {
        #expect(Sound.whiteNoise.next == .pinkNoise)
        #expect(Sound.ocean.next == .whiteNoise)
        #expect(Sound.whiteNoise.previous == .ocean)
        for sound in Sound.allCases { #expect(sound.next.previous == sound) }
    }
}

nonisolated struct SoundOutputTests {
    /// The source node's block runs where the engine calls it, here off the main thread as on the
    /// audio thread, and makes the sound: past the fade-in, well above silence.
    @Test @concurrent func rendersThroughAnEngineOffTheMainThread() async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let source = SoundOutput.source(for: .rain, format: format)
        engine.attach(source)
        try engine.connectNode(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        var peak: Float = 0
        for _ in 0..<30 {
            #expect(try engine.renderOffline(4_096, to: buffer) == .success)
            let samples = try #require(buffer.floatChannelData)[0]
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[frame])) }
        }
        #expect(peak > 0.05)
    }
}

struct SoundPlayerTests {
    @Test func playsPausesAndStopsTheOutput() {
        #expect(SoundPlayer.target(for: .playing, sound: .rain, isSteppedAside: false) == .playing(.rain))
        #expect(SoundPlayer.target(for: .paused, sound: .rain, isSteppedAside: false) == .paused)
        #expect(SoundPlayer.target(for: .stopped, sound: .rain, isSteppedAside: false) == .stopped)
    }

    /// An open video's player has the audio, whether the sound was playing or paused.
    @Test func handsTheAudioToAVideo() {
        #expect(SoundPlayer.target(for: .playing, sound: .boxFan, isSteppedAside: true) == .handedOver)
        #expect(SoundPlayer.target(for: .paused, sound: .boxFan, isSteppedAside: true) == .handedOver)
        #expect(SoundPlayer.target(for: .stopped, sound: .boxFan, isSteppedAside: true) == .stopped)
    }

    @Test func offersSleepTimersFromAQuarterHourToANight() {
        #expect(SleepTimer.choices.first == .off)
        #expect(SleepTimer.choices.map(\.label).contains("15 Minutes"))
        #expect(SleepTimer.minutes(60).label == "1 Hour")
        #expect(SleepTimer.minutes(480).label == "8 Hours")
        #if os(tvOS)
        #expect(SleepTimer.choices.last == .minutes(480))
        #else
        #expect(SleepTimer.choices.last == .whenDownloadsFinish)
        #expect(SleepTimer.whenDownloadsFinish.label == "When Downloads Finish")
        #endif
    }
}
