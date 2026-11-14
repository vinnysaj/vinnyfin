import Foundation

/// A picture size someone wants: for streaming, and separately for downloads.
nonisolated enum VideoQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Whatever the best version is, untouched.
    case original
    case uhd = "2160p"
    case fullHD = "1080p"
    case hd = "720p"
    case sd = "480p"

    var id: Self { self }

    var label: String {
        switch self {
        case .original: "Best Available"
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        case .sd: "480p"
        }
    }

    /// Nil when there is no limit.
    var maxHeight: Int? {
        switch self {
        case .original: nil
        case .uhd: 2160
        case .fullHD: 1080
        case .hd: 720
        case .sd: 480
        }
    }

    /// The bitrate a transcode to this size is asked for.
    var transcodeBitrate: Int {
        switch self {
        case .original: 120_000_000
        case .uhd: 60_000_000
        case .fullHD: 16_000_000
        case .hd: 6_000_000
        case .sd: 2_500_000
        }
    }

    /// The sizes with a limit, largest first.
    static let limited: [VideoQuality] = [.uhd, .fullHD, .hd, .sd]

    /// The smallest limit a picture `height` lines tall fits in.
    static func fitting(height: Int) -> VideoQuality {
        limited.last { ($0.maxHeight ?? .max) >= height } ?? .original
    }
}

/// What a version of a title is, as far as picking one goes.
nonisolated struct VersionTraits: Equatable, Sendable {
    /// The picture's class in lines: 2160, 1080, 720 and so on. Nil when nothing says.
    let resolutionClass: Int?
    /// Bits per second, as the server measured the file. Nil when it hasn't, as for a remote
    /// stream before it is first opened.
    let bitrate: Int?

    init(_ source: MediaSource) {
        resolutionClass = Self.resolutionClass(of: source)
        bitrate = source.bitrate.flatMap { $0 > 100_000 ? $0 : nil }
    }

    /// The bitrate, or failing that a generous guess from the picture's class: what a transcode
    /// to that size is asked for.
    var estimatedBitrate: Int? {
        bitrate ?? resolutionClass.map { VideoQuality.fitting(height: $0).transcodeBitrate }
    }

    /// "4K", "1080p": the class as the quality settings name it.
    static func label(forResolution resolution: Int) -> String {
        resolution == 2160 ? VideoQuality.uhd.label : "\(resolution)p"
    }

    /// From the video stream's size, treating a wide 1920x800 as 1080p; failing that, from
    /// the version's name ("4K HDR", "1080p WEB-DL"), which is all a remote stream has
    /// before it is first opened.
    static func resolutionClass(of source: MediaSource) -> Int? {
        if let video = source.videoStream, let width = video.width, let height = video.height, width > 0, height > 0 {
            return snap(max(height, width * 9 / 16))
        }
        let text = [source.name, source.videoStream?.displayTitle].compactMap(\.self).joined(separator: " ").lowercased()
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !tokens.isDisjoint(with: ["2160p", "4k", "uhd", "2160"]) { return 2160 }
        if !tokens.isDisjoint(with: ["1440p", "2k", "1440"]) { return 1440 }
        if !tokens.isDisjoint(with: ["1080p", "1080i", "fhd", "1080"]) { return 1080 }
        if !tokens.isDisjoint(with: ["720p", "720"]) { return 720 }
        if !tokens.isDisjoint(with: ["576p", "540p", "480p", "sd", "dvd", "480", "576"]) { return 480 }
        return nil
    }

    /// Rounds a measured height to the class it was mastered at, so 1036 or 1088 is 1080.
    static func snap(_ height: Int) -> Int {
        let classes = [4320, 2160, 1440, 1080, 720, 576, 480, 360, 240]
        return classes.min { abs($0 - height) < abs($1 - height) } ?? height
    }
}

/// How to get a version to the screen.
nonisolated enum PlaybackPlan: Equatable, Sendable {
    /// The original file, as it is.
    case direct(MediaSource)
    /// The server scales this version down to `quality`.
    case transcode(MediaSource, VideoQuality)

    var source: MediaSource {
        switch self {
        case .direct(let source), .transcode(let source, _): source
        }
    }

    var isTranscode: Bool {
        if case .transcode = self { true } else { false }
    }

    /// The picture size it plays at, as the quality settings name it: "4K", "720p". Nil when
    /// nothing says.
    var label: String? {
        switch self {
        case .direct(let source): VersionTraits(source).resolutionClass.map(VersionTraits.label(forResolution:))
        case .transcode(_, let quality): quality.label
        }
    }
}

nonisolated enum VersionChooser {
    /// The version to download at `quality`, as `choose(from:limit:)` picks one.
    static func choose(from sources: [MediaSource], quality: VideoQuality) -> MediaSource? {
        choose(from: sources, limit: StreamingLimit(quality: quality))
    }

    /// The version to play within `limit`: the best one within it, in the order of `sources`,
    /// which is the item's own version first and the rest in the server's order, as
    /// `JellyfinClient.item` lists them (remote-stream plugins rank theirs best first). With no
    /// picture size to keep to, the item's own version unless it's known to be over the bitrate.
    /// When none is within it, one that may be, else the smallest, which `planStreaming` then has
    /// the server scale down.
    static func choose(from sources: [MediaSource], limit: StreamingLimit) -> MediaSource? {
        guard limit.maxHeight != nil || limit.bitrate != nil else { return sources.first }
        let versions = sources.map { (source: $0, traits: VersionTraits($0)) }
        if limit.maxHeight == nil, let first = versions.first, limit.admits(first.traits) != false { return first.source }
        // `max(by:)` and `min(by:)` return the first of equal elements, so ties keep the server's order.
        let within = versions.filter { limit.admits($0.traits) == true }
        if let best = within.max(by: { ($0.traits.resolutionClass ?? 0) < ($1.traits.resolutionClass ?? 0) }) { return best.source }
        // Nothing known is within it: one that may be is tried before scaling one down.
        if let unknown = versions.first(where: { limit.admits($0.traits) == nil }) { return unknown.source }
        return versions.min { limit.excess($0.traits) < limit.excess($1.traits) }?.source
    }

    /// Streaming: the chosen version as it is when it's within the limit, otherwise scaled down
    /// by the server when transcoding is allowed.
    static func planStreaming(sources: [MediaSource], preferred: MediaSource?, limit: StreamingLimit, allowTranscoding: Bool) -> PlaybackPlan? {
        guard let source = preferred ?? choose(from: sources, limit: limit) else { return nil }
        guard allowTranscoding, limit.admits(VersionTraits(source)) == false, let quality = limit.transcodeQuality
        else { return .direct(source) }
        return .transcode(source, quality)
    }

    /// A cheaper way to go on playing a title when the connection can't keep up with `playing`:
    /// the best version below it that the connection carries, else a transcode it carries, when
    /// transcoding is allowed. Without a measured throughput it takes one step: the next version
    /// down, else the next transcode down. When nothing fits the throughput, the cheapest there
    /// is. Nil when nothing is cheaper.
    ///
    /// - Parameters:
    ///   - bitrate: What `playing` was measured at, in bits per second, when it was.
    ///   - throughput: What the connection delivers, in bits per second, when it was measured.
    static func planStepDown(from playing: PlaybackPlan, bitrate: Int?, throughput: Int?,
                             sources: [MediaSource], allowTranscoding: Bool) -> PlaybackPlan? {
        struct Option {
            let plan: PlaybackPlan
            let bitrate: Int
            let resolution: Int?
            /// Ranks the dearest first, keeping the server's order between equals.
            let order: Int
            func isDearer(than other: Option) -> Bool {
                (bitrate, resolution ?? 0, -order) > (other.bitrate, other.resolution ?? 0, -other.order)
            }
        }
        let currentResolution: Int?
        let currentBitrate: Int?
        switch playing {
        case .direct(let source):
            currentResolution = VersionTraits(source).resolutionClass
            currentBitrate = bitrate ?? VersionTraits(source).estimatedBitrate
        case .transcode(_, let quality):
            currentResolution = quality.maxHeight
            currentBitrate = bitrate ?? quality.transcodeBitrate
        }
        guard let currentBitrate else { return nil }
        // A step has to save enough to be worth the pause it costs, and never makes the picture bigger.
        func isCheaper(bitrate: Int, resolution: Int?) -> Bool {
            if let resolution, let currentResolution, resolution > currentResolution { return false }
            return Double(bitrate) <= Double(currentBitrate) * 0.85
        }
        let versions = sources.enumerated().compactMap { index, source -> Option? in
            let traits = VersionTraits(source)
            guard let estimate = traits.estimatedBitrate, isCheaper(bitrate: estimate, resolution: traits.resolutionClass) else { return nil }
            return Option(plan: .direct(source), bitrate: estimate, resolution: traits.resolutionClass, order: index)
        }
        let transcodes = !allowTranscoding ? [] : VideoQuality.limited.enumerated().compactMap { index, quality -> Option? in
            guard isCheaper(bitrate: quality.transcodeBitrate, resolution: quality.maxHeight) else { return nil }
            let source = transcodeSource(for: quality, from: sources) ?? playing.source
            return Option(plan: .transcode(source, quality), bitrate: quality.transcodeBitrate, resolution: quality.maxHeight, order: index)
        }
        let dearestFirst = { (options: [Option]) in options.sorted { $0.isDearer(than: $1) } }
        guard let throughput else {
            return (dearestFirst(versions).first ?? dearestFirst(transcodes).first)?.plan
        }
        // Room for the connection's dips and for the audio.
        let budget = Double(throughput) * 0.8
        let fits = { (option: Option) in Double(option.bitrate) <= budget }
        if let version = dearestFirst(versions).first(where: fits) { return version.plan }
        if let transcode = dearestFirst(transcodes).first(where: fits) { return transcode.plan }
        return dearestFirst(versions + transcodes).last?.plan
    }

    /// A dearer way to go on playing a title once the connection has recovered from a step down:
    /// the best way between `playing` and `ceiling`, the way the title started, that a link holding
    /// `throughput` carries with room to spare. Ranks by picture size, then a version as it is over
    /// the server's conversion, then bitrate. A title that started as a conversion steps up only
    /// to conversions of the same version: none of its versions fit as they are, or this device
    /// couldn't play it. Nil when nothing dearer fits, or `playing` is the ceiling already.
    ///
    /// - Parameters:
    ///   - throughput: What the link has held, in bits per second (`RecoveryWatch.heldThroughput`).
    static func planStepUp(from playing: PlaybackPlan, toward ceiling: PlaybackPlan, throughput: Int,
                           sources: [MediaSource], allowTranscoding: Bool) -> PlaybackPlan? {
        guard playing != ceiling, let current = StepUpOption(playing), let top = StepUpOption(ceiling) else { return nil }
        let budget = Double(throughput) / stepUpHeadroom
        let versions: [PlaybackPlan] = ceiling.isTranscode ? [] : sources.map { .direct($0) }
        let transcodes: [PlaybackPlan] = !allowTranscoding && !ceiling.isTranscode ? [] : VideoQuality.limited.map { quality in
            let source = ceiling.isTranscode ? ceiling.source : transcodeSource(for: quality, from: sources) ?? playing.source
            return .transcode(source, quality)
        }
        let better = (versions + transcodes).compactMap(StepUpOption.init).filter { option in
            // Worth the pause it costs, never a smaller picture, and no more than the title started at.
            (option.resolution > current.resolution || Double(option.bitrate) >= Double(current.bitrate) * 1.15)
                && option.resolution >= current.resolution
                && option.resolution <= top.resolution && option.bitrate <= top.bitrate
                && Double(option.bitrate) <= budget
        }
        return better.max { ($0.resolution, $0.isDirect ? 1 : 0, $0.bitrate) < ($1.resolution, $1.isDirect ? 1 : 0, $1.bitrate) }?.plan
    }

    /// A step up has to fit the link this many times over, so a dip doesn't bring it back down.
    static let stepUpHeadroom: Double = 1.5

    /// A way of playing for ranking a step up: what it asks of the link and the size it plays at.
    private struct StepUpOption {
        let plan: PlaybackPlan
        let bitrate: Int
        let resolution: Int
        var isDirect: Bool { !plan.isTranscode }

        init?(_ plan: PlaybackPlan) {
            switch plan {
            case .direct(let source):
                let traits = VersionTraits(source)
                guard let bitrate = traits.estimatedBitrate else { return nil }
                self.bitrate = bitrate
                resolution = traits.resolutionClass ?? 0
            case .transcode(_, let quality):
                bitrate = quality.transcodeBitrate
                resolution = quality.maxHeight ?? 0
            }
            self.plan = plan
        }
    }

    /// What to offer when this device can't draw `playing`'s picture fast enough: the version with
    /// the next smaller picture, else the server's conversion at the size `limit` allows, or 1080p
    /// without one. Nil for a conversion, which the server already makes light.
    static func lighter(than playing: PlaybackPlan, sources: [MediaSource], limit: StreamingLimit) -> PlaybackPlan? {
        guard case .direct(let source) = playing else { return nil }
        let height = VersionTraits(source).resolutionClass ?? .max
        let smaller = sources.filter { (VersionTraits($0).resolutionClass ?? .max) < height }
        if let best = smaller.max(by: { (VersionTraits($0).resolutionClass ?? 0) < (VersionTraits($1).resolutionClass ?? 0) }) {
            return .direct(best)
        }
        guard source.supportsTranscoding != false else { return nil }
        return .transcode(source, limit.transcodeQuality ?? .fullHD)
    }

    /// The version a transcode to `quality` is best made from: the smallest that is at least
    /// that size, which is the least for the server to read and scale.
    private static func transcodeSource(for quality: VideoQuality, from sources: [MediaSource]) -> MediaSource? {
        let height = quality.maxHeight ?? 0
        return sources.filter { (VersionTraits($0).resolutionClass ?? 0) >= height }.min { lhs, rhs in
            let (left, right) = (VersionTraits(lhs), VersionTraits(rhs))
            return (left.resolutionClass ?? 0, left.estimatedBitrate ?? .max) < (right.resolutionClass ?? 0, right.estimatedBitrate ?? .max)
        }
    }
}
