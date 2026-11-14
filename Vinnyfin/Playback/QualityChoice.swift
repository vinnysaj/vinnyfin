import AetherEngine
import Foundation

/// A way to play the title on screen that the Quality panel offers.
nonisolated enum QualityOption: Hashable, Sendable {
    /// What the streaming limit allows, which with Adaptive Quality moves down when the connection
    /// can't keep up and back up once it recovers.
    case auto
    /// A version as it is.
    case version(MediaSource)
    /// The version playing, converted by the server to a smaller size.
    case converted(VideoQuality)

    /// The ways to play a title whose versions are `sources`, `playing` among them: Auto, each
    /// version, and each size the server can convert `playing` to that saves something, the
    /// largest first. None for a version the server won't convert.
    static func all(sources: [MediaSource], playing: MediaSource) -> [QualityOption] {
        let traits = VersionTraits(playing)
        let height = traits.resolutionClass ?? .max
        let bitrate = traits.estimatedBitrate ?? .max
        let sizes = playing.supportsTranscoding == false ? [] : VideoQuality.limited.filter { quality in
            let lines = quality.maxHeight ?? .max
            return lines < height || (lines == height && Double(quality.transcodeBitrate) <= Double(bitrate) * 0.85)
        }
        return [.auto] + sources.map(QualityOption.version) + sizes.map(QualityOption.converted)
    }
}

/// Why the stream playing is the version, or the size, it is.
nonisolated enum QualityReason: Equatable, Sendable {
    /// The streaming limit's choice as the title started; `hold` is what held it below the
    /// version it would otherwise have played, when something did.
    case streamingLimit(StreamingLimit.Hold?)
    /// Picked on the title's page.
    case pickedOnPage
    /// Picked in the Quality panel.
    case picked
    /// The connection couldn't keep up with a dearer one.
    case connectionSlowed
    /// The connection recovered after it had moved down.
    case connectionRecovered
    /// This device couldn't play the version as it is.
    case deviceCouldNotPlay
    /// This device couldn't draw a larger picture fast enough.
    case pictureFellBehind

    /// Why a title started as `plan`: picked on its page, or chosen within `limit`, held back by
    /// what kept the version it would otherwise have played from playing as it is.
    static func started(_ plan: PlaybackPlan, sources: [MediaSource], pickedOnPage: Bool, limit: StreamingLimit) -> QualityReason {
        // With nothing to keep to, the item's own version plays (`VersionChooser.choose`).
        let wanted = pickedOnPage ? plan.source : sources.first ?? plan.source
        if case .direct(let source) = plan, source.id == wanted.id { return pickedOnPage ? .pickedOnPage : .streamingLimit(nil) }
        return .streamingLimit(limit.hold(on: VersionTraits(wanted)))
    }
}

/// What the Quality panel says plays, and why.
nonisolated struct QualityStatus: Equatable, Sendable {
    /// "Converted to 720p, the connection slowed"
    let summary: String
    /// "From 4K · up to 6 Mbps"
    let detail: String?

    init(summary: String, detail: String?) {
        self.summary = summary
        self.detail = detail
    }

    /// A stream of the title whose versions are `sources`.
    init(plan: PlaybackPlan, reason: QualityReason, sources: [MediaSource]) {
        let what = Self.what(plan, sources: sources)
        summary = Self.why(reason).map { "\(what), \($0)" } ?? what
        switch plan {
        case .direct(let source):
            let parts = [source.videoStream?.displayTitle, VersionTraits(source).bitrate.map(QualityLearning.label(forBitrate:))]
            let line = parts.compactMap(\.self).joined(separator: " · ")
            detail = line.isEmpty ? nil : line
        case .transcode(let source, let quality):
            let from = PlaybackPlan.direct(source).label.map { "From \($0) · " } ?? ""
            detail = "\(from)up to \(QualityLearning.label(forBitrate: quality.transcodeBitrate))"
        }
    }

    /// "Original · 4K" for the best version as it is, "1080p version" for another, "Converted to
    /// 720p" for the server's conversion.
    static func what(_ plan: PlaybackPlan, sources: [MediaSource]) -> String {
        switch plan {
        case .transcode(_, let quality):
            return "Converted to \(quality.label)"
        case .direct(let source):
            let label = plan.label
            guard isBest(source, among: sources) else { return label.map { "\($0) version" } ?? source.name ?? "Another version" }
            return label.map { "Original · \($0)" } ?? "Original"
        }
    }

    /// Why, as the end of a sentence about what plays; nil when there's nothing to explain.
    static func why(_ reason: QualityReason) -> String? {
        switch reason {
        case .streamingLimit(nil): nil
        case .streamingLimit(.setting(let quality)): "Streaming Quality is set to \(quality.label)"
        case .streamingLimit(.display(let lines)): "this TV shows \(VersionTraits.label(forResolution: lines))"
        case .streamingLimit(.learnedBitrate(let bitrate)): "the connection here carries about \(QualityLearning.label(forBitrate: bitrate))"
        case .pickedOnPage: "picked on the title's page"
        case .picked: "as you chose"
        case .connectionSlowed: "the connection slowed"
        case .connectionRecovered: "the connection recovered"
        case .deviceCouldNotPlay: "this device can't play the original"
        case .pictureFellBehind: "this device couldn't keep up with a larger picture"
        }
    }

    /// The version with the largest picture, the first of equals.
    private static func isBest(_ source: MediaSource, among sources: [MediaSource]) -> Bool {
        guard sources.count > 1 else { return true }
        let best = sources.max { (VersionTraits($0).resolutionClass ?? 0) < (VersionTraits($1).resolutionClass ?? 0) }
        return best?.id == source.id || VersionTraits(source).resolutionClass == best.flatMap { VersionTraits($0).resolutionClass }
    }
}

/// Whether a transcode that failed mid-playback is asked of the server again, behind
/// "Reconnecting…": the server may have lost it, as when it restarts, while the title and the
/// connection are fine. Once at a time: a stream that fails again before it has played
/// `playsBeforeAnother` seconds since stays failed. A file that plays as it is gets no such
/// try, as the engine rides out a dropped connection itself.
nonisolated struct TranscodeReconnect: Equatable, Sendable {
    static let playsBeforeAnother: Double = 60

    /// Seconds played since the last reconnect; nil when there was none.
    private(set) var playedSinceReconnect: Double?

    mutating func played(_ seconds: Double) {
        if let played = playedSinceReconnect { playedSinceReconnect = played + seconds }
    }

    /// Whether to reconnect after a failure the engine described as `info`, of a transcode that
    /// had shown its picture; counts the reconnect when it does.
    mutating func shouldReconnect(after info: PlaybackErrorInfo?, isTranscode: Bool, hadPicture: Bool) -> Bool {
        guard isTranscode, hadPicture, Self.mayRecover(from: info) else { return false }
        if let played = playedSinceReconnect, played < Self.playsBeforeAnother { return false }
        playedSinceReconnect = 0
        return true
    }

    /// A failure a fresh transcode may get past: not a sign-in the server no longer takes or an
    /// account it won't serve, a certificate it doesn't trust, a full device, or a picture this
    /// device can't show.
    static func mayRecover(from info: PlaybackErrorInfo?) -> Bool {
        guard let info else { return true }
        switch info.kind {
        case .sourceRefused: return info.underlyingCode != 401 && info.underlyingCode != 403
        case .sourceCertificateRejected, .storageExhausted, .dolbyVisionRequiresHardware: return false
        default: return true
        }
    }
}

/// Something the player offers while sound plays with no picture: a lighter way to play the
/// title, by the button that takes it.
nonisolated struct PictureOffer: Equatable, Sendable {
    let plan: PlaybackPlan
    /// "Play 1080p", "Play Through the Server"
    let action: String

    init(plan: PlaybackPlan) {
        self.plan = plan
        action = switch plan {
        case .direct: plan.label.map { "Play \($0)" } ?? "Play Another Version"
        case .transcode: "Play Through the Server"
        }
    }
}
