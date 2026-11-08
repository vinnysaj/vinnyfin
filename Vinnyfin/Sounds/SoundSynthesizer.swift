import Foundation

/// A sound to fall asleep or settle down to, in Sounds (`SoundPlayer`).
nonisolated enum Sound: String, CaseIterable, Identifiable, Sendable {
    case whiteNoise
    case pinkNoise
    case brownNoise
    case boxFan
    case oscillatingFan
    case ceilingFan
    case airConditioner
    case rain
    case ocean

    var id: Self { self }

    var name: String {
        switch self {
        case .whiteNoise: "White Noise"
        case .pinkNoise: "Pink Noise"
        case .brownNoise: "Brown Noise"
        case .boxFan: "Box Fan"
        case .oscillatingFan: "Oscillating Fan"
        case .ceilingFan: "Ceiling Fan"
        case .airConditioner: "Air Conditioner"
        case .rain: "Rain"
        case .ocean: "Ocean Waves"
        }
    }

    var systemImage: String {
        switch self {
        case .whiteNoise: "waveform"
        case .pinkNoise: "waveform.mid"
        case .brownNoise: "waveform.low"
        case .boxFan: "fan"
        case .oscillatingFan: "fan.oscillation"
        case .ceilingFan: "fan.ceiling"
        case .airConditioner: "air.conditioner.horizontal"
        case .rain: "cloud.rain"
        case .ocean: "water.waves"
        }
    }

    /// The one after this, going round, for the Lock Screen's next track.
    var next: Sound {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var previous: Sound {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

/// Makes a `Sound` as it plays, a buffer at a time on the audio thread, so there's no recording
/// to ship and no seam where one would loop. Every sound is noise, shaped: filtered for its color,
/// with a motor's hum, a fan's blades and turn, raindrops, or the swell of waves. Each channel has
/// noise of its own, so the sound is wide rather than in the middle of the head, and it fades in
/// over `fadeInDuration` rather than starting with a click.
///
/// Nothing in `render` allocates, locks or calls into the system.
nonisolated struct SoundSynthesizer {
    static let fadeInDuration: Double = 1.5
    /// How loud every sound is, in LUFS: well under music's -14, as these play for hours, often
    /// at night.
    static let loudness = -20.0
    /// What the loudest moments may reach, short of full scale.
    static let ceiling: Float = 0.98

    let sound: Sound
    let sampleRate: Double

    private var left: Voice
    private var right: Voice
    /// Chooses the waves' lengths and heights, the same for both channels.
    private var shared: Noise
    private var fade: Float = 0
    private let fadeStep: Float
    /// Turns of the slow movements, from 0 up to 1: a motor's hum, a fan's blades and its turn
    /// from side to side, a ceiling fan's sweep, the rain's swell.
    private var hum = 0.0
    private var blades = 0.0
    private var turn = 0.0
    private var swell = 0.0
    private var waves: Waves
    private let filters: Filters
    private let gain: Float

    init(sound: Sound, sampleRate: Double, seed: UInt64 = .random(in: 1...UInt64.max)) {
        self.sound = sound
        self.sampleRate = sampleRate
        left = Voice(seed: seed)
        right = Voice(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        shared = Noise(seed: seed ^ 0xD1B5_4A32_D192_ED03)
        waves = Waves()
        fadeStep = Float(1 / (Self.fadeInDuration * sampleRate))
        filters = Filters(sampleRate: sampleRate)
        gain = Self.gain(for: sound)
        waves.begin(using: &shared, sampleRate: sampleRate)
    }

    /// Fills both channels with the next `left.count` frames.
    mutating func render(left leftOut: UnsafeMutableBufferPointer<Float>, right rightOut: UnsafeMutableBufferPointer<Float>) {
        for frame in 0..<min(leftOut.count, rightOut.count) {
            var (l, r) = next()
            fade = min(1, fade + fadeStep)
            l *= gain * fade
            r *= gain * fade
            leftOut[frame] = max(-Self.ceiling, min(Self.ceiling, l))
            rightOut[frame] = max(-Self.ceiling, min(Self.ceiling, r))
        }
    }

    // MARK: Sounds

    private mutating func next() -> (Float, Float) {
        switch sound {
        case .whiteNoise:
            return (left.noise.white(), right.noise.white())
        case .pinkNoise:
            return (left.pink(), right.pink())
        case .brownNoise:
            return (left.brown(), right.brown())
        case .boxFan:
            // A motor's hum under air, with the blades just audible as they pass.
            let motor = Float(sin(2 * .pi * hum) * 0.02 + sin(4 * .pi * hum) * 0.008)
            let passing = Float(1 + 0.05 * sin(2 * .pi * blades))
            Self.advance(&hum, by: 58, at: sampleRate)
            Self.advance(&blades, by: 9, at: sampleRate)
            return (left.boxFan(filters) * passing + motor, right.boxFan(filters) * passing + motor)
        case .oscillatingFan:
            // Turning from side to side, and a little louder as it faces you.
            let facing = Float(cos(2 * .pi * turn))
            Self.advance(&turn, by: 1 / 16, at: sampleRate)
            return (left.breeze(filters) * (0.7 + 0.3 * facing), right.breeze(filters) * (0.7 - 0.3 * facing))
        case .ceilingFan:
            // A slow sweep each time a blade goes over.
            let sweep = Float(0.7 + 0.3 * (0.5 + 0.5 * sin(2 * .pi * blades)))
            Self.advance(&blades, by: 1.4, at: sampleRate)
            return (left.ceilingFan(filters) * sweep, right.ceilingFan(filters) * sweep)
        case .airConditioner:
            let compressor = Float(sin(2 * .pi * hum) * 0.012 + sin(4 * .pi * hum) * 0.008 + sin(6 * .pi * hum) * 0.004)
            Self.advance(&hum, by: 50, at: sampleRate)
            return (left.airConditioner(filters) + compressor, right.airConditioner(filters) + compressor)
        case .rain:
            let heaviness = Float(0.85 + 0.15 * sin(2 * .pi * swell))
            Self.advance(&swell, by: 1 / 23, at: sampleRate)
            return (left.rain(filters) * heaviness, right.rain(filters) * heaviness)
        case .ocean:
            let wave = waves.next(using: &shared, sampleRate: sampleRate)
            return (left.ocean(wave), right.ocean(wave))
        }
    }

    /// Brings every sound to about `loudness`, measured, so changing sounds doesn't change how
    /// loud it is, and leaves the loudest moments short of `ceiling`.
    static func gain(for sound: Sound) -> Float {
        switch sound {
        case .whiteNoise: 0.085
        case .pinkNoise: 0.38
        case .brownNoise: 0.42
        case .boxFan: 0.48
        case .oscillatingFan: 0.81
        case .ceilingFan: 0.76
        case .airConditioner: 0.62
        case .rain: 0.68
        case .ocean: 1.17
        }
    }

    private static func advance(_ phase: inout Double, by hertz: Double, at sampleRate: Double) {
        phase += hertz / sampleRate
        if phase >= 1 { phase -= 1 }
    }

    /// The one-pole low-pass coefficient for `cutoff` hertz.
    static func lowPass(_ cutoff: Double, _ sampleRate: Double) -> Float {
        Float(1 - exp(-2 * .pi * cutoff / sampleRate))
    }
}

// MARK: Parts

/// xorshift64*: fast, and plenty random for noise.
nonisolated struct Noise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x2545_F491_4F6C_DD1D : seed
    }

    private mutating func bits() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform in -1..<1.
    mutating func white() -> Float {
        Float(Int32(truncatingIfNeeded: bits() >> 32)) / 2_147_483_648
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Float {
        Float(bits() >> 40) / 16_777_216
    }
}

/// The one-pole coefficients for the cutoffs the sounds use, and the raindrops' timing, worked
/// out once for the sample rate.
nonisolated private struct Filters {
    let fan: Float
    let breeze: Float
    let ceiling: Float
    let unit: Float
    /// Rain's wash, between these.
    let washFloor: Float
    let washTop: Float
    /// Each raindrop's tap, between these.
    let tapFloor: Float
    let tapTop: Float
    /// How quickly a drop rises, so it taps rather than clicks.
    let tapRise: Float
    /// How much of a drop is left a frame later.
    let tapDecay: Float
    /// The chance in a frame of a small drop starting, and of a close one.
    let patterChance: Float
    let closeChance: Float

    init(sampleRate: Double) {
        fan = SoundSynthesizer.lowPass(900, sampleRate)
        breeze = SoundSynthesizer.lowPass(1_800, sampleRate)
        ceiling = SoundSynthesizer.lowPass(450, sampleRate)
        unit = SoundSynthesizer.lowPass(1_400, sampleRate)
        washFloor = SoundSynthesizer.lowPass(200, sampleRate)
        washTop = SoundSynthesizer.lowPass(1_800, sampleRate)
        tapFloor = SoundSynthesizer.lowPass(500, sampleRate)
        tapTop = SoundSynthesizer.lowPass(2_600, sampleRate)
        tapRise = Float(1 - exp(-1 / (0.001 * sampleRate)))
        tapDecay = Float(exp(-1 / (0.012 * sampleRate)))
        patterChance = Float(220 / sampleRate)
        closeChance = Float(5 / sampleRate)
    }
}

/// A one-pole filter: the low part of what goes through it, or what's left above that.
nonisolated private struct OnePole {
    private var state: Float = 0

    mutating func low(_ input: Float, _ coefficient: Float) -> Float {
        state += coefficient * (input - state)
        return state
    }

    mutating func high(_ input: Float, _ coefficient: Float) -> Float {
        input - low(input, coefficient)
    }
}

/// One channel's noise and filters.
nonisolated private struct Voice {
    var noise: Noise
    /// Paul Kellet's pink filter's poles.
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    private var integrated: Float = 0
    /// Shapes each sound's main body of noise; `smooth` steepens it where one pole isn't enough.
    private var body = OnePole()
    private var smooth = OnePole()
    /// Rain's: what's below the wash, the drops' rise, and what's outside their tap.
    private var washFloor = OnePole()
    private var tapRise = OnePole()
    private var tapFloor = OnePole()
    private var tapTop = OnePole()
    private var tapSmooth = OnePole()
    /// How loud the raindrops under way still are, together.
    private var drops: Float = 0

    init(seed: UInt64) {
        noise = Noise(seed: seed)
    }

    /// Pink noise, falling 3 dB an octave: Paul Kellet's refined filter on white noise.
    mutating func pink() -> Float {
        let white = noise.white()
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return pink * 0.11
    }

    /// Brown noise, falling 6 dB an octave: white noise integrated, leaking back to zero so it
    /// doesn't wander off.
    mutating func brown() -> Float {
        integrated = (integrated + 0.02 * noise.white()) / 1.02
        return integrated * 3.5
    }

    // MARK: Sounds

    mutating func boxFan(_ filters: Filters) -> Float {
        let air = pink()
        return body.low(air, filters.fan) * 1.4 + brown() * 0.25
    }

    mutating func breeze(_ filters: Filters) -> Float {
        let air = pink()
        return body.low(air, filters.breeze)
    }

    mutating func ceilingFan(_ filters: Filters) -> Float {
        let air = brown() * 0.8 + pink() * 0.4
        return body.low(air, filters.ceiling)
    }

    mutating func airConditioner(_ filters: Filters) -> Float {
        let air = pink()
        return brown() * 0.32 + body.low(air, filters.unit) * 0.9
    }

    /// Soft rain: a wash of rain falling everywhere, rolled off above the hiss, and a patter of
    /// many small drops nearby, now and then a closer one. Each drop rises over a millisecond and
    /// dies away over a few more, and only its middle frequencies are kept, so it taps rather
    /// than clicks.
    mutating func rain(_ filters: Filters) -> Float {
        let hiss = pink()
        let above = washFloor.high(hiss, filters.washFloor)
        let wash = smooth.low(body.low(above, filters.washTop), filters.washTop) + brown() * 0.25
        if noise.unit() < filters.patterChance { drops += 0.04 + 0.16 * noise.unit() }
        if noise.unit() < filters.closeChance { drops += 0.12 + 0.2 * noise.unit() }
        drops *= filters.tapDecay
        let envelope = tapRise.low(drops, filters.tapRise)
        let burst = noise.white() * envelope
        let band = tapFloor.high(burst, filters.tapFloor)
        let tap = tapSmooth.low(tapTop.low(band, filters.tapTop), filters.tapTop)
        return wash + tap * 1.3
    }

    /// Deep and quiet between waves, and brighter and louder as each one breaks.
    mutating func ocean(_ wave: Waves.Moment) -> Float {
        let surf = brown() * 0.7 + pink() * 0.5
        return body.low(surf, wave.lowPass) * wave.level
    }
}

/// Waves coming in one after another, each its own length and height: a quick rise as it breaks
/// and a long fall as it washes out.
nonisolated private struct Waves {
    struct Moment {
        /// How loud the surf is, from the quiet between waves up to the break.
        var level: Float
        /// The one-pole coefficient: the surf is brighter as it breaks.
        var lowPass: Float
    }

    static let shortest = 7.0
    static let longest = 12.0
    /// How often the brightness is worked out again, in frames: it moves slowly, and the
    /// exponential it takes is the costliest thing here.
    static let refresh = 32

    private var progress = 0.0
    private var step = 0.0
    private var height: Float = 1
    private var countdown = 0
    private var moment = Moment(level: 0, lowPass: 0)

    mutating func begin(using noise: inout Noise, sampleRate: Double) {
        startWave(using: &noise, sampleRate: sampleRate)
    }

    mutating func next(using noise: inout Noise, sampleRate: Double) -> Moment {
        if countdown == 0 {
            countdown = Self.refresh
            let swell = height * Self.shape(Float(progress))
            moment = Moment(level: 0.18 + 0.82 * swell,
                            lowPass: SoundSynthesizer.lowPass(200 + 2_200 * Double(swell * swell.squareRoot()), sampleRate))
        }
        countdown -= 1
        progress += step
        if progress >= 1 { startWave(using: &noise, sampleRate: sampleRate) }
        return moment
    }

    private mutating func startWave(using noise: inout Noise, sampleRate: Double) {
        progress = 0
        let length = Self.shortest + (Self.longest - Self.shortest) * Double(noise.unit())
        step = 1 / (length * sampleRate)
        height = 0.55 + 0.45 * noise.unit()
    }

    /// Up over the first 30% of the wave, down over the rest, smoothly at both ends.
    static func shape(_ progress: Float) -> Float {
        func smooth(_ x: Float) -> Float { x * x * (3 - 2 * x) }
        return progress < 0.3 ? smooth(progress / 0.3) : 1 - smooth((progress - 0.3) / 0.7)
    }
}
