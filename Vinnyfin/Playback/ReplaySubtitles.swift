import Foundation

/// Subtitles for what plays again after a skip back, as Apple TV's player turns them on for it, so
/// a line missed the first time can be read: from the skip back until the playhead is back where
/// it was, then as they were.
nonisolated struct ReplaySubtitles: Equatable {
    /// Where playback was when the first skip back of the run came; at it, the subtitles go back.
    private(set) var until: Double
    /// The subtitles before, which come back: nil for none, else forced subtitles' track.
    let before: Int?
    /// The track shown for what plays again.
    let shown: Int

    init(until: Double, before: Int?, shown: Int) {
        self.until = until
        self.before = before
        self.shown = shown
    }

    /// The subtitles a skip back shows, among `candidates`, while `showing` shows: full subtitles
    /// in the forced subtitles' language, else in `language` (the subtitle setting's), else in the
    /// audio's. With `captions` (Closed Captions + SDH) closed captions come first. Nil when full
    /// subtitles show already, or there are none in those languages.
    static func track(in candidates: [TrackChooser.Candidate], showing: Int?, language: String, audioLanguage: String?,
                      captions: Bool) -> Int? {
        let current = showing.flatMap { id in candidates.first { $0.id == id } }
        if let current, !current.showsOnlyForced { return nil }
        let full = candidates.filter { !$0.showsOnlyForced }
        for spoken in [current?.language, language, audioLanguage] {
            let inLanguage = full.filter { AppSettings.sameLanguage($0.language, spoken) }
            let pick = captions ? inLanguage.first(where: \.isCaptions) ?? inLanguage.first
                                : inLanguage.first { !$0.isCaptions } ?? inLanguage.first
            if let pick { return pick.id }
        }
        return nil
    }

    /// Another skip back of the run, from `time`: the subtitles stay until the playhead is back
    /// where the first one began, or where this one did, if further on.
    mutating func skippedBack(from time: Double) {
        until = max(until, time)
    }

    /// Follows the playhead, at `time`. Returns true once it has played on to where the replay
    /// began, having first been seen back before it: until the skip back lands, the playhead can
    /// still read where it skipped from.
    mutating func playhead(at time: Double) -> Bool {
        if time < until - Self.landing { hasGoneBack = true }
        return hasGoneBack && time >= until
    }

    /// How far back from where it skipped the playhead is to have landed the skip.
    private static let landing = 1.0
    private var hasGoneBack = false
}
