import Foundation

/// What to watch next: each movie partway through, and for each show being watched the one
/// episode to go on with, the title played last first. Home's first row, the Top Shelf, the
/// widget, a show's Play button and Siri all go by it.
///
/// A show's episode partway through is next when it was played after the last episode finished.
/// Otherwise the next is the first episode not yet watched after the one finished last. The
/// server's own pick goes on from the furthest episode watched instead, which a later episode
/// marked watched by mistake pushes past what's being watched, so it stands only when it comes
/// right after the one finished last. An episode that hasn't aired, or has nothing to play yet,
/// is never next.
nonisolated enum UpNext {
    /// The most entries a list holds.
    static let longestList = 60
    /// How many of the episodes finished last tell which shows are being watched, and where.
    static let historyLength = 100
    /// How many episodes on from the one finished last to look through for the next.
    static let lookahead = 50

    /// What's known of how one show is being watched.
    struct Show: Sendable, Equatable {
        let seriesId: String
        /// The episode partway through that was played last.
        var inProgress: JellyfinItem?
        /// The episode finished last.
        var finished: JellyfinItem?
        /// The server's next episode, which isn't one partway through.
        var serverNext: JellyfinItem?

        /// When anything of the show was last played.
        var lastPlayed: Date? {
            [inProgress?.lastPlayedDate, finished?.lastPlayedDate].compactMap(\.self).max()
        }
    }

    /// What a show's next episode is, as far as its `Show` tells.
    enum Pick: Equatable, Sendable {
        case episode(JellyfinItem)
        /// The first episode to watch after this one, which only its following episodes tell.
        case after(JellyfinItem)
        /// Caught up, or nothing of it watched.
        case nothing
    }

    static func pick(for show: Show, now: Date) -> Pick {
        let serverNext = show.serverNext.flatMap { isAvailable($0, now: now) ? $0 : nil }
        if let inProgress = show.inProgress,
           (inProgress.lastPlayedDate ?? .distantPast) >= (show.finished?.lastPlayedDate ?? .distantPast) {
            return .episode(inProgress)
        }
        if let finished = show.finished {
            if let serverNext, follows(serverNext, finished) { return .episode(serverNext) }
            return .after(finished)
        }
        return serverNext.map(Pick.episode) ?? .nothing
    }

    /// Whether `episode` is numbered right after `previous`, in the same season.
    static func follows(_ episode: JellyfinItem, _ previous: JellyfinItem) -> Bool {
        guard let season = previous.parentIndexNumber, let number = previous.indexNumberEnd ?? previous.indexNumber else { return false }
        return episode.parentIndexNumber == season && episode.indexNumber == number + 1
    }

    /// How many episodes on from one the player looks through for the one to go on to, past
    /// specials and episodes not out yet.
    static let neighbourReach = 6

    /// The first episode to watch after `previous`, from the show's episodes in order from it on:
    /// not watched, not a special, aired and with something to play.
    static func firstToWatch(after previous: JellyfinItem, in following: [JellyfinItem], now: Date) -> JellyfinItem? {
        episodes(after: previous.id, in: following).first { !$0.isPlayed && canGoOn(to: $0, now: now) }
    }

    /// The episode the player goes on to after `episodeId`, watched or not, from the show's
    /// episodes in order from it on: the Next button's, and the up-next card's.
    static func episode(after episodeId: String, in following: [JellyfinItem], now: Date) -> JellyfinItem? {
        episodes(after: episodeId, in: following).first { canGoOn(to: $0, now: now) }
    }

    /// Whether the player can go on to `episode` from the one beside it: not a special, aired and
    /// with something to play.
    static func canGoOn(to episode: JellyfinItem, now: Date) -> Bool {
        episode.parentIndexNumber != 0 && isAvailable(episode, now: now)
    }

    /// Aired, and with something to play.
    static func isAvailable(_ episode: JellyfinItem, now: Date) -> Bool {
        !episode.isNotYetAvailable(now: now)
    }

    private static func episodes(after episodeId: String, in following: [JellyfinItem]) -> ArraySlice<JellyfinItem> {
        following.firstIndex { $0.id == episodeId }.map { following[($0 + 1)...] } ?? following[...]
    }

    /// The shows being watched, from what's partway through, the episodes finished last and the
    /// server's next episodes. All three lists come the latest first.
    static func shows(inProgress: [JellyfinItem], finished: [JellyfinItem], serverNext: [JellyfinItem]) -> [Show] {
        var order: [String] = []
        var shows: [String: Show] = [:]
        func update(_ episode: JellyfinItem, _ change: (inout Show) -> Void) {
            guard episode.isEpisode, let seriesId = episode.seriesId else { return }
            if shows[seriesId] == nil {
                order.append(seriesId)
                shows[seriesId] = Show(seriesId: seriesId)
            }
            change(&shows[seriesId]!)
        }
        for episode in inProgress { update(episode) { if $0.inProgress == nil { $0.inProgress = episode } } }
        for episode in finished { update(episode) { if $0.finished == nil { $0.finished = episode } } }
        for episode in serverNext { update(episode) { if $0.serverNext == nil { $0.serverNext = episode } } }
        return order.compactMap { shows[$0] }
    }

    /// One title in the list, before a show's episode is settled.
    enum Title: Equatable, Sendable {
        case movie(JellyfinItem)
        case show(Show)

        var lastPlayed: Date? {
            switch self {
            case .movie(let movie): movie.lastPlayedDate
            case .show(let show): show.lastPlayed
            }
        }
    }

    /// Movies partway through and the shows being watched, the one played last first, leaving out
    /// the shows taken out of the list here (`HiddenShows`) that nothing has been played of since.
    /// A show only the server's next episodes know of was played before any the history reaches,
    /// and follows, in the server's order.
    static func titles(movies: [JellyfinItem], shows: [Show], hidden: [String: Date] = [:]) -> [Title] {
        let all = movies.map(Title.movie) + shows.filter { !isHidden($0, marks: hidden) }.map(Title.show)
        let dated = all.enumerated().filter { $0.element.lastPlayed != nil }.sorted { left, right in
            let leftDate = left.element.lastPlayed ?? .distantPast, rightDate = right.element.lastPlayed ?? .distantPast
            return leftDate != rightDate ? leftDate > rightDate : left.offset < right.offset
        }
        return dated.map(\.element) + all.filter { $0.lastPlayed == nil }
    }

    /// One title in the list: what to play, and when anything of the movie or show was last
    /// played, which taking it out of the list goes by.
    struct Entry: Equatable, Sendable {
        let item: JellyfinItem
        let lastPlayed: Date?
    }

    /// Whether a show taken out of the list stays out: nothing of it played since it was, when
    /// `marks` has when it was last played then.
    static func isHidden(_ show: Show, marks: [String: Date]) -> Bool {
        guard let mark = marks[show.seriesId] else { return false }
        return (show.lastPlayed ?? .distantPast) <= mark
    }

    /// The shows in `marks` played since they were taken out, which are back in the list.
    static func returned(_ shows: [Show], marks: [String: Date]) -> [String] {
        shows.filter { marks[$0.seriesId] != nil && !isHidden($0, marks: marks) }.map(\.seriesId)
    }

    /// Shows taken out of the list on this device, each kept out until something of it is played
    /// again: by show, when anything of it was last played as it was taken out. The server has no
    /// way to leave a show out of its lists, and a show's next episode, worked out afresh from its
    /// history each time, would otherwise come straight back. They're kept where the app's
    /// extensions read them, so the Top Shelf and the widgets leave them out too.
    struct HiddenShows {
        /// The most shows kept out at once; past it, those taken out first come back.
        static let limit = 200

        let userId: String
        let defaults: UserDefaults

        init(userId: String, defaults: UserDefaults = AccountStore.savedDefaults) {
            self.userId = userId
            self.defaults = defaults
        }

        private var key: String { "upNext.hiddenShows.\(userId)" }

        /// When anything of each show kept out was last played as it was taken out.
        var marks: [String: Date] {
            guard let saved = defaults.dictionary(forKey: key) as? [String: Double] else { return [:] }
            return saved.mapValues { Date(timeIntervalSinceReferenceDate: $0) }
        }

        /// Keeps the show out until something of it is played after `lastPlayed`, or for a show
        /// never played, at all.
        func hide(seriesId: String, lastPlayed: Date?) {
            var saved = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
            saved[seriesId] = (lastPlayed ?? .distantPast).timeIntervalSinceReferenceDate
            if saved.count > Self.limit {
                for (id, _) in saved.sorted(by: { $0.value < $1.value }).prefix(saved.count - Self.limit) { saved[id] = nil }
            }
            defaults.set(saved, forKey: key)
        }

        /// Lets the shows back into the list.
        func letBack(_ seriesIds: [String]) {
            guard var saved = defaults.dictionary(forKey: key) as? [String: Double],
                  seriesIds.contains(where: { saved[$0] != nil }) else { return }
            for id in seriesIds { saved[id] = nil }
            defaults.set(saved, forKey: key)
        }
    }
}

extension JellyfinClient {
    /// What to watch next, up to `limit` titles (see `UpNext`).
    func upNext(userId: String, limit: Int) async throws -> ItemsPage {
        let items = try await upNextEntries(userId: userId, limit: limit).map(\.item)
        return ItemsPage(items: items, totalRecordCount: items.count)
    }

    /// What to watch next, up to `limit` titles, each with when anything of it was last played
    /// (see `UpNext`). Shows taken out of the list on this device stay out (`UpNext.HiddenShows`),
    /// and those played since are let back in.
    func upNextEntries(userId: String, limit: Int,
                       hidden: UpNext.HiddenShows? = nil) async throws -> [UpNext.Entry] {
        let hidden = hidden ?? UpNext.HiddenShows(userId: userId)
        let wanted = min(limit, UpNext.longestList)
        async let resume = resumeItems(userId: userId, limit: UpNext.longestList)
        async let finished = finishedEpisodes(userId: userId, limit: UpNext.historyLength)
        async let serverNext = nextUp(userId: userId, resumable: false, limit: UpNext.longestList)
        let inProgress = try await resume.items
        let shows = try await UpNext.shows(inProgress: inProgress, finished: finished, serverNext: serverNext.items)
        let marks = hidden.marks
        hidden.letBack(UpNext.returned(shows, marks: marks))
        let titles = UpNext.titles(movies: inProgress.filter { !$0.isEpisode }, shows: shows, hidden: marks)
        let now = Date.now
        // A caught-up show drops out of the list, so a few more than wanted are settled.
        let considered = Array(titles.prefix(wanted + wanted / 2 + 4))
        let settled = try await withThrowingTaskGroup(of: (Int, JellyfinItem?).self) { group in
            for (position, title) in considered.enumerated() {
                group.addTask {
                    switch title {
                    case .movie(let movie): (position, movie)
                    case .show(let show): (position, try await next(in: show, userId: userId, now: now))
                    }
                }
            }
            var settled: [Int: JellyfinItem] = [:]
            for try await (position, item) in group { settled[position] = item }
            return settled
        }
        let entries = considered.indices.compactMap { position in
            settled[position].map { UpNext.Entry(item: $0, lastPlayed: considered[position].lastPlayed) }
        }
        return Array(entries.prefix(wanted))
    }

    /// A show's next episode to watch, or nil when there's none: caught up, or, for a show
    /// nothing of has been watched, without episodes.
    func upNext(seriesId: String, userId: String) async throws -> JellyfinItem? {
        async let resume = resumeItems(userId: userId, parentId: seriesId, limit: 1)
        async let finished = finishedEpisodes(userId: userId, seriesId: seriesId, limit: 1)
        async let serverNext = nextUp(userId: userId, seriesId: seriesId, resumable: false, limit: 1)
        let show = try await UpNext.Show(seriesId: seriesId, inProgress: resume.items.first(where: \.isEpisode),
                                         finished: finished.first, serverNext: serverNext.items.first)
        return try await next(in: show, userId: userId, now: .now)
    }

    private func next(in show: UpNext.Show, userId: String, now: Date) async throws -> JellyfinItem? {
        switch UpNext.pick(for: show, now: now) {
        case .episode(let episode):
            return episode
        case .nothing:
            return nil
        case .after(let finished):
            let following = try await episodes(from: finished.id, seriesId: show.seriesId, userId: userId, limit: UpNext.lookahead)
            guard let found = UpNext.firstToWatch(after: finished, in: following, now: now) else {
                // Nothing to watch within reach: the server's next, past the furthest watched, if any.
                return show.serverNext.flatMap { UpNext.isAvailable($0, now: now) ? $0 : nil }
            }
            return try await listedItems(in: ItemsPage(items: [found], totalRecordCount: 1), userId: userId).items.first
        }
    }
}
