import Foundation

/// What the up-next card is about, for an episode with one after it.
nonisolated enum UpNextPhase: Equatable, Sendable {
    /// The last half minute of an episode with no credits marked. The card only offers the next
    /// episode: with the controls hidden, a click brings them up with Play Now ready, so a click
    /// meant for the last scene doesn't skip it.
    case nearEnd
    /// The credits the server marks (an Outro segment). With autoplay the next episode counts
    /// down from their start, and Watch Credits keeps them.
    case credits
    /// The episode has ended. Its next one is the way on, counting down with autoplay.
    case ended
}

/// The end of a title on its timeline: where its credits start, from the Outro segment the server
/// marks, and when the up-next card offers the next episode. The card, the countdown and the
/// position the server hears when the viewer leaves during the credits all go by it.
nonisolated struct TitleEnding: Equatable, Sendable {
    let duration: Double
    let segments: [MediaSegment]

    /// Titles this short, such as extras, get no card.
    static let shortestWithUpNext: Double = 120
    /// Without credits marked, the card offers the next episode this close to the end.
    static let nearEndWindow: Double = 30

    /// Where the credits start, when the server marks them.
    var creditsStart: Double? {
        segments.first { $0.type == "Outro" }?.start
    }

    func isInCredits(at time: Double) -> Bool {
        creditsStart.map { time >= $0 } ?? false
    }

    /// What the card is about at `time`, for an episode with a next one; nil before it's due.
    func upNextPhase(at time: Double, hasEnded: Bool) -> UpNextPhase? {
        guard duration > Self.shortestWithUpNext else { return nil }
        if hasEnded { return .ended }
        if isInCredits(at: time) { return .credits }
        return duration - time <= Self.nearEndWindow ? .nearEnd : nil
    }

    /// Whether leaving the title at `position` finishes it: once its credits start, or moving on
    /// to the next episode while the card offers it. The server then hears it played to the end,
    /// so it's marked watched and leaves Continue Watching.
    func finishes(leavingAt position: Double, toNextEpisode: Bool) -> Bool {
        isInCredits(at: position) || toNextEpisode && upNextPhase(at: position, hasEnded: false) != nil
    }
}

/// Counts the episodes that started by themselves since the viewer last did anything. After
/// `limit` of them, the player asks whether anyone is still watching rather than starting
/// another, so a season doesn't play through, and get marked watched, overnight.
nonisolated struct UnattendedAutoplay: Equatable, Sendable {
    static let limit = 3

    private(set) var count = 0

    /// The next episode waits for an answer instead of counting down.
    var asksFirst: Bool { count >= Self.limit }

    mutating func episodeStartedByItself() {
        count += 1
    }

    mutating func viewerActed() {
        count = 0
    }
}

/// Where the end screen of a movie, or of a show's last episode, leads back to: the title's own
/// page, or for an episode its show's.
nonisolated struct EndScreenReturn: Equatable, Sendable {
    let page: JellyfinItem
    let label: String

    init(for item: JellyfinItem) {
        if item.isEpisode, let seriesId = item.seriesId {
            let show = item.seriesName ?? ""
            page = JellyfinItem(id: seriesId, name: show, type: "Series")
            label = show.isEmpty ? "Back to the Show" : "Back to \(show)"
        } else {
            page = item
            label = "Back to Details"
        }
    }
}
