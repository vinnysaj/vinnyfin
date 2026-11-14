#if !os(tvOS)
import Foundation

/// The finished downloads as Downloads lists them: movies by title, then a group for each show,
/// shows by name, each with its episodes in order and the smart download that keeps it. A show
/// kept downloaded has its group with nothing downloaded too, to change or stop that from.
nonisolated struct DownloadGroups {
    struct Show: Identifiable {
        /// The show's id, or for an episode saved without it, its show's name (`DownloadJob.showKey`).
        let id: String
        let name: String
        /// Nil for episodes saved without it, which can't lead to their show.
        let seriesId: String?
        var episodes: [DownloadJob] = []
        var rule: SmartDownloads.Rule?

        /// The room its episodes take, with their extras.
        var bytes: Int64 { episodes.reduce(0) { $0 + $1.storedBytes } }
    }

    let movies: [DownloadJob]
    let shows: [Show]

    init(finished: [DownloadJob], rules: [SmartDownloads.Rule]) {
        movies = finished.filter { !$0.isEpisode }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var shows: [String: Show] = [:]
        for job in finished where job.isEpisode {
            shows[job.showKey, default: Show(id: job.showKey, name: job.showName, seriesId: job.seriesId)].episodes.append(job)
        }
        for rule in rules {
            shows[rule.seriesId, default: Show(id: rule.seriesId, name: rule.seriesName, seriesId: rule.seriesId)].rule = rule
        }
        self.shows = shows.values
            .map { show in
                var show = show
                show.episodes.sort { Self.order(of: $0) < Self.order(of: $1) }
                return show
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Season, then episode.
    private static func order(of job: DownloadJob) -> Int {
        (job.item?.parentIndexNumber ?? 0) * 10_000 + (job.item?.indexNumber ?? 0)
    }
}

nonisolated extension DownloadJob {
    /// The show an episode is of, as Downloads groups it: its id, or for one saved without it, its name.
    var showKey: String { seriesId ?? showName }

    /// The name of the show an episode is of.
    var showName: String { item?.seriesName ?? subtitle ?? "Other" }
}

/// The watched episodes of a show that Delete Watched Episodes deleted lately, for its section of
/// Downloads to say what went, and why.
nonisolated struct WatchedRemoval: Codable, Equatable, Sendable {
    /// Each episode's code, "S01E01", or its title when it has none.
    var episodes: [String]
    var bytes: Int64
    /// When the last of them went.
    var date: Date

    /// How long a removal is told of: deletions that run on are told of together.
    static let shownFor: TimeInterval = 7 * 24 * 3600

    func isRecent(at now: Date) -> Bool {
        now.timeIntervalSince(date) < Self.shownFor
    }

    /// `removals`, by `DownloadJob.showKey`, with `deleted` episodes added to their shows' recent
    /// removals, and the removals no longer recent left out.
    static func adding(_ deleted: [DownloadJob], to removals: [String: WatchedRemoval], at now: Date) -> [String: WatchedRemoval] {
        var removals = removals.filter { $0.value.isRecent(at: now) }
        for job in deleted where job.isEpisode {
            let name = job.item?.episodeCode ?? job.title
            if var removal = removals[job.showKey] {
                if !removal.episodes.contains(name) { removal.episodes.append(name) }
                removal.bytes += job.storedBytes
                removal.date = now
                removals[job.showKey] = removal
            } else {
                removals[job.showKey] = WatchedRemoval(episodes: [name], bytes: job.storedBytes, date: now)
            }
        }
        return removals
    }
}
#endif
