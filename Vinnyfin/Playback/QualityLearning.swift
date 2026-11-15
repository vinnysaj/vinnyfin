import Foundation

/// What this device learns about its connection from the streams that rebuffer on it: a bitrate
/// to stay under. Each rebuffer the connection causes is an incident; once streams at or above
/// some bitrate have rebuffered as `Rules` asks, on separate days and in different titles, the
/// device keeps a step below that bitrate until it's reset.
nonisolated struct QualityLearning: Codable, Equatable, Sendable {
    /// What it takes to learn a limit, and how far below the trouble the limit goes. Streams at or
    /// above a bitrate have to have rebuffered
    enum Rules {
        /// this many times,
        static let incidents = 3
        /// on this many separate days, so one bad evening can't teach a limit,
        static let days = 3
        /// in this many titles, a show's episodes counting as one, so one flaky file can't either,
        static let titles = 2
        /// within this many seconds before the latest;
        static let window: TimeInterval = 30 * 24 * 60 * 60
        /// and on this many of those days, in as many titles, at no more than a step above it, so
        /// the limit comes from trouble near it: one stream that rebuffered far below the rest
        /// can't drag it down.
        static let nearby = 2
        /// Days start at this hour, so an evening that runs past midnight is one day.
        static let dayStartHour = 5
        /// A step: the limit is this share of the bitrate that kept rebuffering, rounded down to a
        /// whole megabit...
        static let stepDown = 0.7
        /// ...and never below the smallest transcode's bitrate.
        static let lowestLimit = VideoQuality.sd.transcodeBitrate
        /// A freeze with this many seconds buffered ahead or more had the stream at hand, so
        /// something other than the connection held it up.
        static let drainedBuffer: Double = 10
    }

    /// A stream that rebuffered because the connection couldn't carry it.
    struct Incident: Codable, Equatable, Sendable {
        var date: Date
        /// What the stream asked of the connection, in bits per second: its bitrate at the speed
        /// it played.
        var bitrate: Int
        /// The picture's class in lines; nil when nothing says.
        var resolution: Int?
        /// The title's id, or for an episode its show's.
        var title: String
    }

    /// The bitrate to stay under, in bits per second; nil until one is learned.
    private(set) var limit: Int?
    /// The incidents that may still teach a limit: those within `Rules.window` before the latest,
    /// at or under `limit`.
    private(set) var incidents: [Incident] = []

    init() {}

    /// Takes an incident. Returns the limit it teaches, when it teaches a new one.
    @discardableResult
    mutating func record(_ incident: Incident, calendar: Calendar = .current) -> Int? {
        incidents.append(incident)
        incidents.removeAll { incident.date.timeIntervalSince($0.date) > Rules.window || $0.bitrate > limit ?? .max }
        guard let trouble = troubleBitrate(calendar: calendar) else { return nil }
        let learned = max(Rules.lowestLimit, Int(Double(trouble) * Rules.stepDown / 1_000_000) * 1_000_000)
        guard learned < limit ?? .max else { return nil }
        limit = learned
        // What streamed above the new limit is spent: what's learned next is learned within it.
        incidents.removeAll { $0.bitrate > learned }
        return learned
    }

    /// Forgets the limit and every incident.
    mutating func reset() {
        self = QualityLearning()
    }

    /// The highest bitrate at or above which streams rebuffered as `Rules` asks; nil when none has.
    private func troubleBitrate(calendar: Calendar) -> Int? {
        func days(_ incidents: [Incident]) -> Int { Set(incidents.map { Self.day(of: $0.date, calendar: calendar) }).count }
        func titles(_ incidents: [Incident]) -> Int { Set(incidents.map(\.title)).count }
        return Set(incidents.map(\.bitrate)).sorted(by: >).first { bitrate in
            let above = incidents.filter { $0.bitrate >= bitrate }
            let nearby = above.filter { Double($0.bitrate) * Rules.stepDown <= Double(bitrate) }
            return above.count >= Rules.incidents && days(above) >= Rules.days && titles(above) >= Rules.titles
                && days(nearby) >= Rules.nearby && titles(nearby) >= Rules.nearby
        }
    }

    /// The start of the day `date` falls in, days starting at `Rules.dayStartHour`.
    static func day(of date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-Double(Rules.dayStartHour) * 60 * 60))
    }

    /// "20 Mbps", "2.5 Mbps", and under a megabit, which would read "0 Mbps", "350 kbps".
    static func label(forBitrate bitrate: Int) -> String {
        guard bitrate >= 1_000_000 else { return "\((Double(bitrate) / 1_000).rounded().formatted()) kbps" }
        return "\((Double(bitrate) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)))) Mbps"
    }
}

nonisolated extension QualityLearning.Incident {
    /// The incident `reason` makes of the stream playing, when the connection caused it. Nil when
    /// it says nothing about the connection: a slow start, which includes opening the file and the
    /// server getting going, as after a seek; a transcode, whose server may be what's behind; a
    /// remote stream, whose origin may be; a freeze with the stream buffered ahead, or with the
    /// link measured carrying it; and anything on cellular data or a Personal Hotspot, which isn't
    /// the connection the device is usually on.
    ///
    /// - Parameters:
    ///   - sample: The sample `ConnectionWatch` gave `reason` for.
    ///   - throughput: What the link was measured carrying, in bits per second, when it was.
    init?(_ reason: ConnectionWatch.Reason, playing plan: PlaybackPlan, of item: JellyfinItem, sample: ConnectionWatch.Sample,
          throughput: Double?, isExpensiveNetwork: Bool, date: Date = .now) {
        guard case .direct(let source) = plan, source.isRemote != true, !isExpensiveNetwork else { return nil }
        let traits = VersionTraits(source)
        guard let bitrate = traits.bitrate.map(Double.init) ?? sample.bitrate else { return nil }
        let demand = bitrate * sample.rate
        guard demand > 0 else { return nil }
        switch reason {
        case .slowStart:
            return nil
        case .stalled, .stuttering:
            if sample.bufferedAhead >= QualityLearning.Rules.drainedBuffer { return nil }
            if let throughput, throughput >= demand { return nil }
        case .fallingBehind:
            break
        }
        self.init(date: date, bitrate: Int(demand), resolution: traits.resolutionClass, title: item.seriesId ?? item.id)
    }
}
