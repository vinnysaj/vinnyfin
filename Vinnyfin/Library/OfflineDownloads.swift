#if !os(tvOS)
import Foundation

/// What's downloaded, as Home and Search offer it while the server is out of reach: the finished
/// downloads of the sign-in in use, by their titles, each once whatever versions of it are here.
nonisolated enum OfflineDownloads {
    /// The titles of `account`'s finished downloads, and those saved before downloads had a
    /// sign-in: first those not watched yet, the last played first, then the newest downloaded;
    /// then those watched. `entry` is this device's history of an item.
    static func titles(_ jobs: [DownloadJob], of account: AccountStore.Account?,
                       entry: (String) -> WatchHistory.Entry?) -> [JellyfinItem] {
        let finished = jobs.filter { $0.status == .completed && $0.item != nil && $0.belongs(to: account) }
        let ranked = finished.map { job in
            let local = entry(job.itemId)
            let lastPlayed = [local?.updatedAt, job.item?.lastPlayedDate].compactMap(\.self).max()
            return (job: job, isWatched: job.watchState(local: local).isWatched, lastPlayed: lastPlayed)
        }
        .sorted { left, right in
            if left.isWatched != right.isWatched { return !left.isWatched }
            if left.lastPlayed != right.lastPlayed { return (left.lastPlayed ?? .distantPast) > (right.lastPlayed ?? .distantPast) }
            return left.job.createdAt > right.job.createdAt
        }
        var seen: Set<String> = []
        return ranked.compactMap { ranked in
            guard let item = ranked.job.item, seen.insert(item.id).inserted else { return nil }
            return item
        }
    }

    /// The downloaded titles matching `term` by name, by their show's name, or by the name of
    /// their file, by kind, the closest matches first.
    static func search(_ term: String, in titles: [JellyfinItem], fileNames: [String: String] = [:]) -> SearchResults {
        let matched = titles.compactMap { item -> (item: JellyfinItem, match: SearchMatch)? in
            let names = [item.name, item.seriesName, fileNames[item.id]].compactMap(\.self)
            let match = names.map { SearchMatch(name: $0, term: term) }.max() ?? .none
            return match > .none ? (item, match) : nil
        }
        .sorted { left, right in
            if left.match != right.match { return left.match > right.match }
            return left.item.name.localizedStandardCompare(right.item.name) == .orderedAscending
        }
        .map(\.item)
        return SearchResults(movies: matched.filter { !$0.isEpisode && !BrowseList.videoTypes.contains($0.type) },
                             videos: matched.filter { BrowseList.videoTypes.contains($0.type) },
                             episodes: matched.filter(\.isEpisode))
    }

    /// The names of the downloads' files, without their folders or extensions, by item.
    static func fileNames(of jobs: [DownloadJob]) -> [String: String] {
        Dictionary(jobs.map { ($0.itemId, String($0.destinationStem.split(separator: "/").last ?? "")) }) { first, _ in first }
    }
}
#endif
