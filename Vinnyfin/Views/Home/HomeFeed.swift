import Foundation
import Observation
import SwiftUI

/// Home's rows and their titles. One round of requests fills the banner and the first rows and
/// says what the rest are; each of the rest loads as it comes near the screen, a few at a time.
/// A row picked for Home that turns out to hold too little, or to repeat the rows above it, gives
/// way (`HomeRows.givesWay`), decided once every row above it is in, so it's settled before it
/// shows. Coming back to Home refreshes Continue Watching in place and keeps the rows as they
/// were, so nothing moves under the viewer; a pull to refresh, or coming back after `freshness`
/// away, picks the rows again.
@MainActor @Observable
final class HomeFeed {
    /// Requests at once for rows coming on screen.
    static let width = 3
    /// Rows past the last one on screen to load ahead of scrolling.
    static let lookahead = 2
    /// How long Home can be away, off screen or in the background, and come back as it was.
    nonisolated static let freshness: TimeInterval = 30 * 60

    /// The rows in order; while the first round of requests is out, the ones it fills, as
    /// placeholders. It starts empty: on Apple TV, focus goes to the sidebar at launch and moves
    /// to Home when something focusable arrives there after Home's first frame.
    private(set) var rows: [HomeRow] = []
    /// Each row's titles, once loaded and settled; empty rows aren't shown.
    private(set) var items: [HomeRow.ID: [JellyfinItem]] = [:]
    /// Why a row couldn't load.
    private(set) var problems: [HomeRow.ID: String] = [:]
    /// Rows that gave way to the rows above them, and don't show.
    private(set) var givenWay: Set<HomeRow.ID> = []
    /// Rows holding fewer titles than their list has, whose title opens the rest.
    private(set) var truncated: Set<HomeRow.ID> = []
    /// The titles the banner turns through.
    private(set) var featured: [JellyfinItem] = []
    /// The episode each featured show plays: the next to watch, by show.
    private(set) var featuredEpisodes: [String: JellyfinItem] = [:]
    /// The title last taken out of Continue Watching here, while it can still be put back.
    private(set) var removal: ContinueWatchingRemoval?
    /// Why Home couldn't load, when the server can't be reached.
    private(set) var loadError: String?
    /// The server turned the saved sign-in away (HTTP 401), so retrying won't help.
    private(set) var sessionEnded = false
    /// The server has no movies or shows for this user, so Home has no rows and no banner.
    private(set) var hasNoTitles = false
    /// The first round of requests has come back, at least once.
    private(set) var hasLoaded = false

    /// The first round of requests is out for the first time, and nothing has gone wrong yet:
    /// what Home will show is still to come.
    var isLoadingFirstTime: Bool {
        !hasLoaded && loadError == nil && !sessionEnded && !hasNoTitles
    }

    /// Whether a row shows: not once it has loaded with nothing in it, or given way.
    func isShown(_ id: HomeRow.ID) -> Bool {
        problems[id] != nil || (!givenWay.contains(id) && items[id]?.isEmpty != true)
    }

    @ObservationIgnored private var session: ServerSession?
    /// The first round of requests is out; the rows it fills don't load on their own meanwhile.
    @ObservationIgnored private var isSeeding = false
    /// Picks the rows chosen at random; the same from one load to the next.
    @ObservationIgnored private var randomSeed = UInt64.random(in: .min ... .max)
    /// How many views of each row are on screen; a row's view is replaced as it loads, and the
    /// old one can go after the new one comes.
    @ObservationIgnored private var onScreen: [HomeRow.ID: Int] = [:]
    /// Rows kept through picking the rows again, shown until they load again.
    @ObservationIgnored private var stale: Set<HomeRow.ID> = []
    /// Rows loaded that wait for the rows above them to be in before they settle.
    @ObservationIgnored private var pending: [HomeRow.ID: [JellyfinItem]] = [:]
    /// Titles taken out of rows they stopped fitting by a change made here, and where in each row
    /// they were, until the rows are picked again.
    @ObservationIgnored private var removed: Removals = [:]
    /// When anything of each title in Continue Watching was last played, by the item shown.
    @ObservationIgnored private var lastPlayed: [String: Date?] = [:]
    /// Titles taken out of Continue Watching here, by movie or show, with when anything of each
    /// was last played then: they stay out of it until something of them is played after.
    @ObservationIgnored private var takenOut: [String: Date] = [:]
    /// Each removal's requests to the server, which say whether they went through.
    @ObservationIgnored private var removalWork: [UUID: Task<Bool, Never>] = [:]
    /// Removals put back.
    @ObservationIgnored private var undone: Set<UUID> = []
    /// Since when Home has been off screen or in the background.
    @ObservationIgnored private var awaySince: Date?
    /// Where Home notes whether Continue Watching had titles, for its stand-ins next time.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var queue = LoadQueue<HomeRow.ID>(width: Self.width) { [weak self] id in
        await self?.loadRow(id)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Notes Home leaving the screen, or the app going into the background.
    func wentAway() {
        if awaySince == nil { awaySince = .now }
    }

    /// Loads Home as it comes on screen. The first time, for another sign-in, after a problem,
    /// after `freshness` away, or when `reshuffling`, with new rows picked at random, it picks
    /// the rows; otherwise it refreshes Continue Watching and keeps the rows as they are.
    func load(session: ServerSession, reshuffling: Bool = false) async {
        let away = awaySince.map { Date.now.timeIntervalSince($0) }
        awaySince = nil
        if let current = self.session, current.account != session.account { reset() }
        let isSettled = hasLoaded && loadError == nil && !sessionEnded && !hasNoTitles
        if Self.picksRows(reshuffling: reshuffling, awayFor: away, isSettled: isSettled) {
            await pickRows(session: session, reshuffling: reshuffling)
        } else {
            self.session = session
            await refresh()
        }
    }

    /// Whether Home picks its rows again as it comes on screen, rather than keeping them: when
    /// pulled to refresh, after `freshness` away, or when it isn't showing rows that loaded.
    nonisolated static func picksRows(reshuffling: Bool, awayFor away: TimeInterval?, isSettled: Bool) -> Bool {
        reshuffling || !isSettled || (away ?? 0) >= freshness
    }

    /// Everything of the sign-in before, gone for another's.
    private func reset() {
        queue.cancelAll()
        rows = []
        items = [:]
        problems = [:]
        givenWay = []
        truncated = []
        featured = []
        featuredEpisodes = [:]
        removal = nil
        hasLoaded = false
        stale = []
        pending = [:]
        removed = [:]
        lastPlayed = [:]
        takenOut = [:]
    }

    private func pickRows(session: ServerSession, reshuffling: Bool) async {
        self.session = session
        if reshuffling { randomSeed = .random(in: .min ... .max) }
        // Checking again on a server with nothing on it keeps saying so until something turns up.
        let continueWatchingKey = "home.hadContinueWatching.\(session.account.serverId).\(session.userId)"
        if rows.isEmpty && !hasNoTitles {
            rows = HomeRows.placeholders(continueWatching: defaults.bool(forKey: continueWatchingKey))
        }
        isSeeding = true
        defer {
            isSeeding = false
            schedule()
        }
        let client = session.client
        let userId = session.userId
        func seed(_ row: HomeRow, fields: String) async throws -> ItemsPage {
            guard case .items(var query) = row.list.source else { return ItemsPage(items: [], totalRecordCount: 0) }
            query.fields = fields
            return try await client.page(of: .items(query), userId: userId, startIndex: 0, limit: HomeRows.rowLength)
        }
        do {
            // The banner shows overviews, so the rows it picks from come with them.
            async let upNext = client.upNextEntries(userId: userId, limit: HomeRows.rowLength)
            async let movies = seed(HomeRows.recentMovies, fields: JellyfinClient.listFields)
            async let shows = seed(HomeRows.recentShows, fields: JellyfinClient.listFields)
            async let favorites = seed(HomeRows.favorites, fields: JellyfinClient.cardFields)
            async let watched = Self.recentlyWatched(client: client, userId: userId)
            async let movieGenres = client.genres(userId: userId, types: ["Movie"], withCounts: true)
            async let showGenres = client.genres(userId: userId, types: ["Series"], withCounts: true)
            let entries = try await upNext
            let continueWatching = Self.leavingOut(entries, takenOut: takenOut).map(\.item)
            let pages: [HomeRow.ID: ItemsPage] = try await [
                HomeRows.continueWatching.id: ItemsPage(items: continueWatching, totalRecordCount: continueWatching.count),
                HomeRows.recentMovies.id: movies,
                HomeRows.recentShows.id: shows,
                HomeRows.favorites.id: favorites,
                HomeRows.recentlyWatched.id: ItemsPage(items: watched.played, totalRecordCount: watched.played.count),
            ]
            let seeded = pages.mapValues(\.items)
            let started = try await Self.titles(of: continueWatching, watched: watched.titles, client: client, userId: userId)
            let inputs = try await HomeRows.Inputs(
                watched: watched.titles,
                started: started,
                favorites: favorites.items,
                movieGenres: movieGenres.compactMap { genre in genre.movieCount.map { GenreSize(name: genre.name, count: $0) } },
                showGenres: showGenres.compactMap { genre in genre.seriesCount.map { GenreSize(name: genre.name, count: $0) } }
            )
            var featured = HomeRows.featured(movies: seeded[HomeRows.recentMovies.id, default: []],
                                             shows: seeded[HomeRows.recentShows.id, default: []],
                                             continueWatching: continueWatching)
            if featured.count(where: { !HomeRows.isStarted($0) }) < HomeRows.featuredMinimum,
               let topRated = try? await seed(HomeRows.topRatedUnwatched, fields: JellyfinClient.listFields).items {
                featured = HomeRows.featured(movies: seeded[HomeRows.recentMovies.id, default: []],
                                             shows: seeded[HomeRows.recentShows.id, default: []],
                                             topRated: topRated, continueWatching: continueWatching)
            }
            var random = SeededRandom(seed: randomSeed)
            hasNoTitles = Self.hasNoTitles(seeded)
            // Every row is made of the movies and shows, so without them each would load empty.
            let rows = hasNoTitles ? [] : HomeRows.assemble(inputs, using: &random)
            let ids = Set(rows.map(\.id))
            queue.cancelAll()
            stale = Set(items.keys).intersection(ids).subtracting(seeded.keys)
            items = items.filter { stale.contains($0.key) }
            givenWay.formIntersection(stale)
            truncated = truncated.intersection(stale).union(pages.filter { Self.isTruncated($0.value) }.keys)
            // Continue Watching, worked out whole, has more when it came back as long as asked.
            if entries.count >= HomeRows.rowLength { truncated.insert(HomeRows.continueWatching.id) }
            pending = seeded.filter { ids.contains($0.key) }
            removed = [:]
            problems = [:]
            lastPlayed = Dictionary(entries.map { ($0.item.id, $0.lastPlayed) }, uniquingKeysWith: { first, _ in first })
            self.rows = rows
            settle()
            self.featured = featured
            findFeaturedEpisodes()
            loadError = nil
            sessionEnded = false
            hasLoaded = true
            defaults.set(!continueWatching.isEmpty, forKey: continueWatchingKey)
        } catch JellyfinError.http(status: 401, _) {
            sessionEnded = true
            hasNoTitles = false
            dropPlaceholders()
        } catch {
            guard !error.isCancellation else { return }
            loadError = error.localizedDescription
            hasNoTitles = false
            dropPlaceholders()
        }
    }

    /// Continue Watching again, with what was watched since, and the banner without any of it.
    private func refresh() async {
        guard let session else { return }
        do {
            try await loadContinueWatching(session: session)
        } catch JellyfinError.http(status: 401, _) {
            sessionEnded = true
        } catch {
            // What's shown stays as it was; the next refresh tries again.
        }
    }

    private func loadContinueWatching(session: ServerSession) async throws {
        let id = HomeRows.continueWatching.id
        let entries = try await session.client.upNextEntries(userId: session.userId, limit: HomeRows.rowLength)
        // The server may not have the change that took a title out yet.
        let gone = removed[id] ?? [:]
        let titles = Self.leavingOut(entries, takenOut: takenOut).map(\.item).filter { gone[$0.id] == nil }
        lastPlayed = Dictionary(entries.map { ($0.item.id, $0.lastPlayed) }, uniquingKeysWith: { first, _ in first })
        if entries.count >= HomeRows.rowLength { truncated.insert(id) } else { truncated.remove(id) }
        problems[id] = nil
        if items[id] != titles {
            withAnimation { items[id] = titles }
        }
        // The banner leaves out what's in Continue Watching, and what was watched or started.
        let watching = Set(titles.map(\.titleId))
        let kept = featured.filter { !watching.contains($0.titleId) && !HomeRows.isStarted($0) }
        if !kept.isEmpty, kept.count != featured.count { featured = kept }
    }

    /// Whether a page of a row's list holds fewer titles than the list has: fewer than it has in
    /// all, or as many as a row asks for, from a list that doesn't say how many it has.
    nonisolated static func isTruncated(_ page: ItemsPage) -> Bool {
        page.totalRecordCount > page.items.count || page.items.count >= HomeRows.rowLength
    }

    /// Whether the first round of requests found no movies and no shows: the newest of each
    /// are every one there is, newest first, so none of either means there are none.
    nonisolated static func hasNoTitles(_ seeded: [HomeRow.ID: [JellyfinItem]]) -> Bool {
        seeded[HomeRows.recentMovies.id, default: []].isEmpty && seeded[HomeRows.recentShows.id, default: []].isEmpty
    }

    /// Placeholders of a Home that never loaded give way to what went wrong.
    private func dropPlaceholders() {
        if items.isEmpty { rows = [] }
    }

    func rowAppeared(_ id: HomeRow.ID) {
        onScreen[id, default: 0] += 1
        schedule()
    }

    func rowDisappeared(_ id: HomeRow.ID) {
        onScreen[id, default: 0] -= 1
        if onScreen[id, default: 0] <= 0 { onScreen[id] = nil }
        schedule()
    }

    func retry(_ id: HomeRow.ID) {
        problems[id] = nil
        schedule()
    }

    // MARK: Settling rows

    /// Puts loaded rows in place from the top: each that shows whatever it holds at once, and
    /// each picked for Home once every row above it is in, giving way by what shows above it then.
    private func settle() {
        var above: [[JellyfinItem]] = []
        var waiting = false
        for row in rows {
            let id = row.id
            if let titles = pending[id], !waiting || HomeRows.isKept(id) {
                pending[id] = nil
                if HomeRows.givesWay(id, titles: titles, above: above) { givenWay.insert(id) } else { givenWay.remove(id) }
                items[id] = titles
            }
            guard !givenWay.contains(id) else { continue }
            if let titles = items[id] {
                above.append(titles)
            } else if problems[id] == nil {
                waiting = true
            }
        }
    }

    // MARK: Watch state

    /// Swaps in a title whose watch state changed, wherever it shows. It leaves the rows it no
    /// longer fits, and Continue Watching loads again for what comes after one watched in it,
    /// such as a show's next episode. Changed back, as when the server turns the change down, it
    /// goes back where it was.
    func replace(_ item: JellyfinItem) {
        let left = withAnimation { Self.replace(item, in: &items, removed: &removed) }
        if let position = featured.firstIndex(where: { $0.id == item.id }) { featured[position] = item }
        if left.contains(HomeRows.continueWatching.id), let session {
            Task { try? await loadContinueWatching(session: session) }
        }
    }

    /// Puts in the watch state a playback that ended left its titles in, wherever they show.
    func apply(_ ended: EndedPlayback) {
        var changed: [String: JellyfinItem] = [:]
        for titles in items.values {
            for title in titles where ended.userData[title.id] != nil { changed[title.id] = ended.applied(to: title) }
        }
        withAnimation {
            for item in changed.values { _ = Self.replace(item, in: &items, removed: &removed) }
        }
        featured = ended.applied(to: featured)
    }

    /// Titles taken out of rows, by row, with where in the row each was.
    typealias Removals = [HomeRow.ID: [String: Int]]

    /// `replace(_:)` on `items`: puts `item` in place of its old self in each row it still fits,
    /// takes it out of each it no longer fits, noting where it was in `removed`, and puts it back
    /// there in each it fits again. Returns the rows it left.
    nonisolated static func replace(_ item: JellyfinItem, in items: inout [HomeRow.ID: [JellyfinItem]],
                                    removed: inout Removals) -> Set<HomeRow.ID> {
        var left: Set<HomeRow.ID> = []
        for (id, titles) in items {
            let fits = HomeRows.fits(item, in: id)
            if let position = titles.firstIndex(where: { $0.id == item.id }) {
                if fits {
                    items[id]?[position] = item
                } else {
                    items[id]?.remove(at: position)
                    removed[id, default: [:]][item.id] = position
                    left.insert(id)
                }
            } else if fits, let position = removed[id]?.removeValue(forKey: item.id) {
                items[id]?.insert(item, at: min(position, titles.count))
            }
        }
        return left
    }

    // MARK: Continue Watching

    /// Takes `item` out of Continue Watching, at once here, and for good on the server: a movie's
    /// position, or an episode's partway through, is cleared, so other devices leave it out too,
    /// and an episode's show is kept out of the list on this device until something of it is
    /// played again. Until the toast that offers it goes, `undo(_:)` puts it back. `report` gets
    /// what went wrong, when the server turns it down and it goes back.
    func removeFromContinueWatching(_ item: JellyfinItem, report: @escaping (String) -> Void) {
        let id = HomeRows.continueWatching.id
        guard let session, let position = items[id]?.firstIndex(where: { $0.id == item.id }) else { return }
        let removal = ContinueWatchingRemoval(item: item, position: position, lastPlayed: lastPlayed[item.id] ?? item.lastPlayedDate)
        withAnimation { _ = items[id]?.remove(at: position) }
        takenOut[item.titleId] = removal.lastPlayed ?? .distantPast
        if let show = removal.hidingShow {
            UpNext.HiddenShows(userId: session.userId).hide(seriesId: show, lastPlayed: removal.lastPlayed)
        }
        self.removal = removal
        let client = session.client
        let userId = session.userId
        removalWork[removal.id] = Task {
            do {
                for itemId in removal.clearing {
                    try await client.updateUserData(itemId: itemId, userId: userId, UserDataUpdate(positionTicks: 0, played: nil, lastPlayed: nil))
                }
                return true
            } catch {
                guard !undone.contains(removal.id) else { return false }
                putBack(removal)
                if self.removal?.id == removal.id { self.removal = nil }
                report("Couldn't remove \(item.titleName) from Continue Watching: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Puts a title taken out of Continue Watching back where it was, with its position.
    func undo(_ removal: ContinueWatchingRemoval, report: @escaping (String) -> Void) {
        guard let session, !undone.contains(removal.id) else { return }
        undone.insert(removal.id)
        if self.removal?.id == removal.id { self.removal = nil }
        putBack(removal)
        let work = removalWork.removeValue(forKey: removal.id)
        let client = session.client
        let userId = session.userId
        Task {
            // Its position goes back once it has been cleared, not before.
            guard await work?.value == true, !removal.clearing.isEmpty,
                  let ticks = removal.item.userData?.playbackPositionTicks, ticks > 0 else { return }
            do {
                try await client.updateUserData(itemId: removal.item.id, userId: userId, UserDataUpdate(positionTicks: ticks, played: nil, lastPlayed: nil))
            } catch {
                report("Couldn't put \(removal.item.titleName) back in Continue Watching: \(error.localizedDescription)")
            }
        }
    }

    /// The toast offering to put `removal` back went.
    func settleRemoval(_ removal: ContinueWatchingRemoval) {
        if self.removal?.id == removal.id { self.removal = nil }
    }

    private func putBack(_ removal: ContinueWatchingRemoval) {
        let id = HomeRows.continueWatching.id
        takenOut[removal.item.titleId] = nil
        if let show = removal.hidingShow, let session {
            UpNext.HiddenShows(userId: session.userId).letBack([show])
        }
        guard let titles = items[id], !titles.contains(where: { $0.id == removal.item.id }) else { return }
        withAnimation { items[id]?.insert(removal.item, at: min(removal.position, titles.count)) }
    }

    /// `entries` without the titles taken out of Continue Watching here that nothing has been
    /// played of since: `takenOut` has, by movie or show, when anything of each was last played
    /// as it was taken out.
    nonisolated static func leavingOut(_ entries: [UpNext.Entry], takenOut: [String: Date]) -> [UpNext.Entry] {
        entries.filter { entry in
            guard let mark = takenOut[entry.item.titleId] else { return true }
            return (entry.lastPlayed ?? .distantPast) > mark
        }
    }

    // MARK: Featured shows

    /// The episode a featured show's Play plays: its next to watch, found once.
    func episode(for show: JellyfinItem) async -> JellyfinItem? {
        if let episode = featuredEpisodes[show.id] { return episode }
        guard let session, let episode = try? await session.client.upNext(seriesId: show.id, userId: session.userId) else { return nil }
        featuredEpisodes[show.id] = episode
        return episode
    }

    /// Finds the next episode of each featured show ahead of its turn in the banner.
    private func findFeaturedEpisodes() {
        for show in featured where show.isSeries && featuredEpisodes[show.id] == nil {
            Task { _ = await episode(for: show) }
        }
    }

    // MARK: Loading rows

    /// Loads the rows on screen and the next few below them, and stops loading those gone.
    private func schedule() {
        guard !isSeeding else { return }
        let positions = rows.indices.filter { onScreen[rows[$0].id] != nil }
        guard let first = positions.min(), let last = positions.max() else {
            queue.retain { _ in false }
            return
        }
        let near = rows[first...min(rows.count - 1, last + Self.lookahead)].map(\.id)
        let nearIds = Set(near)
        queue.retain { nearIds.contains($0) }
        queue.want(near.filter { id in
            ((items[id] == nil && pending[id] == nil) || stale.contains(id)) && problems[id] == nil
        })
    }

    private func loadRow(_ id: HomeRow.ID) async {
        guard let session, let row = rows.first(where: { $0.id == id }) else { return }
        if id == HomeRows.continueWatching.id {
            do {
                try await loadContinueWatching(session: session)
                stale.remove(id)
            } catch {
                guard !error.isCancellation else { return }
                if items[id] == nil { problems[id] = error.localizedDescription }
            }
            return
        }
        do {
            let page = try await session.client.page(of: row.list.source, userId: session.userId, startIndex: 0, limit: HomeRows.rowLength)
            // The server may not have the change that took a title out yet.
            let gone = removed[id] ?? [:]
            pending[id] = page.items.filter { gone[$0.id] == nil }
            if Self.isTruncated(page) { truncated.insert(id) } else { truncated.remove(id) }
            stale.remove(id)
            settle()
        } catch {
            guard !error.isCancellation else { return }
            problems[id] = error.localizedDescription
            settle()
        }
    }

    /// What was watched last, for its row, and the movies and shows behind it, with their
    /// genres, for the rows made from them.
    private static func recentlyWatched(client: JellyfinClient, userId: String) async throws -> (played: [JellyfinItem], titles: [JellyfinItem]) {
        guard case .items(var query) = HomeRows.recentlyWatched.list.source else { return ([], []) }
        query.fields = "Genres"
        let played = try await client.page(of: .items(query), userId: userId, startIndex: 0, limit: HomeRows.rowLength).items
        // An episode's own genres are usually empty; its show's say what it is.
        var showIds: [String] = []
        for item in played where item.isEpisode && !showIds.contains(item.titleId) { showIds.append(item.titleId) }
        var shows: [JellyfinItem] = []
        if !showIds.isEmpty {
            var showQuery = JellyfinClient.ItemQuery(types: ["Series"])
            showQuery.ids = showIds
            showQuery.fields = "Genres"
            shows = try await client.items(userId: userId, showQuery).items
        }
        return (played, HomeRows.titles(played: played, shows: shows))
    }

    /// The movies and shows in Continue Watching, with their genres: a show's from those watched,
    /// or else looked up.
    private static func titles(of continueWatching: [JellyfinItem], watched: [JellyfinItem],
                               client: JellyfinClient, userId: String) async throws -> [JellyfinItem] {
        let known = Set(watched.map(\.id))
        var missing: [String] = []
        for item in continueWatching where item.isEpisode && !known.contains(item.titleId) && !missing.contains(item.titleId) {
            missing.append(item.titleId)
        }
        var shows = watched
        if !missing.isEmpty {
            var query = JellyfinClient.ItemQuery(types: ["Series"])
            query.ids = missing
            query.fields = "Genres"
            shows += try await client.items(userId: userId, query).items
        }
        return HomeRows.titles(played: continueWatching, shows: shows)
    }
}

/// A title taken out of Continue Watching here, and what that asks of the server.
nonisolated struct ContinueWatchingRemoval: Identifiable, Equatable, Sendable {
    let id: UUID
    let item: JellyfinItem
    /// Where it was in the row.
    let position: Int
    /// When anything of its movie or show was last played: it stays out of the list until
    /// something of it is played after.
    let lastPlayed: Date?
    /// The items whose position is cleared: a movie's, or an episode's partway through, with each
    /// of its versions, any of which can hold the position.
    let clearing: [String]
    /// The show kept out of the list on this device: an episode's, which would otherwise come
    /// straight back as the show's next.
    let hidingShow: String?

    init(item: JellyfinItem, position: Int, lastPlayed: Date?) {
        id = UUID()
        self.item = item
        self.position = position
        self.lastPlayed = lastPlayed
        let versions = item.mediaSources?.map(\.id).filter { $0 != item.id } ?? []
        clearing = item.isEpisode && item.resumeSeconds == nil ? [] : [item.id] + versions
        hidingShow = item.isEpisode ? item.seriesId : nil
    }
}
