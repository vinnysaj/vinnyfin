import Foundation
import Observation
import SwiftUI

/// Home's rows and their titles. One round of requests fills the banner and the first rows and
/// says what the rest are; each of the rest loads as it comes near the screen, a few at a time.
@MainActor @Observable
final class HomeFeed {
    /// Requests at once for rows coming on screen.
    static let width = 3
    /// Rows past the last one on screen to load ahead of scrolling.
    static let lookahead = 2

    /// The rows in order; while the first round of requests is out, the ones it fills, as
    /// placeholders. It starts empty: on Apple TV, focus goes to the sidebar at launch and moves
    /// to Home when something focusable arrives there after Home's first frame.
    private(set) var rows: [HomeRow] = []
    /// Each row's titles, once loaded; empty rows aren't shown.
    private(set) var items: [HomeRow.ID: [JellyfinItem]] = [:]
    /// Why a row couldn't load.
    private(set) var problems: [HomeRow.ID: String] = [:]
    /// The titles the banner turns through.
    private(set) var featured: [JellyfinItem] = []
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

    @ObservationIgnored private var session: ServerSession?
    /// The first round of requests is out; the rows it fills don't load on their own meanwhile.
    @ObservationIgnored private var isSeeding = false
    /// Picks the rows chosen at random; the same from one load to the next.
    @ObservationIgnored private var randomSeed = UInt64.random(in: .min ... .max)
    /// How many views of each row are on screen; a row's view is replaced as it loads, and the
    /// old one can go after the new one comes.
    @ObservationIgnored private var onScreen: [HomeRow.ID: Int] = [:]
    /// Rows kept through a refresh, shown until they load again.
    @ObservationIgnored private var stale: Set<HomeRow.ID> = []
    /// Titles taken out of rows they stopped fitting by a change made here, and where in each row
    /// they were, until Home loads again.
    @ObservationIgnored private var removed: Removals = [:]
    /// Where Home notes whether Continue Watching had titles, for its stand-ins next time.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var queue = LoadQueue<HomeRow.ID>(width: Self.width) { [weak self] id in
        await self?.loadRow(id)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads Home again, as it comes back on screen to show what changed, or with new rows
    /// picked at random when `reshuffling`.
    func load(session: ServerSession, reshuffling: Bool = false) async {
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
        func seed(_ row: HomeRow, fields: String) async throws -> [JellyfinItem] {
            guard case .items(var query) = row.list.source else { return [] }
            query.fields = fields
            return try await client.page(of: .items(query), userId: userId, startIndex: 0, limit: HomeRows.rowLength).items
        }
        do {
            // The banner shows overviews, so the rows it picks from come with them.
            async let upNext = client.upNext(userId: userId, limit: HomeRows.rowLength)
            async let movies = seed(HomeRows.recentMovies, fields: JellyfinClient.listFields)
            async let shows = seed(HomeRows.recentShows, fields: JellyfinClient.listFields)
            async let favorites = seed(HomeRows.favorites, fields: JellyfinClient.cardFields)
            async let watched = Self.recentlyWatched(client: client, userId: userId)
            async let movieGenres = client.genres(userId: userId, types: ["Movie"], withCounts: true)
            async let showGenres = client.genres(userId: userId, types: ["Series"], withCounts: true)
            let seeded: [HomeRow.ID: [JellyfinItem]] = try await [
                HomeRows.continueWatching.id: upNext.items,
                HomeRows.recentMovies.id: movies,
                HomeRows.recentShows.id: shows,
                HomeRows.favorites.id: favorites,
                HomeRows.recentlyWatched.id: watched.played,
            ]
            let started = try await Self.titles(of: seeded[HomeRows.continueWatching.id, default: []], watched: watched.titles,
                                                client: client, userId: userId)
            let inputs = try await HomeRows.Inputs(
                watched: watched.titles,
                started: started,
                favorites: favorites,
                movieGenres: movieGenres.compactMap { genre in genre.movieCount.map { GenreSize(name: genre.name, count: $0) } },
                showGenres: showGenres.compactMap { genre in genre.seriesCount.map { GenreSize(name: genre.name, count: $0) } }
            )
            var random = SeededRandom(seed: randomSeed)
            hasNoTitles = Self.hasNoTitles(seeded)
            // Every row is made of the movies and shows, so without them each would load empty.
            let rows = hasNoTitles ? [] : HomeRows.assemble(inputs, using: &random)
            let ids = Set(rows.map(\.id))
            queue.cancelAll()
            stale = Set(items.keys).intersection(ids).subtracting(seeded.keys)
            items = items.filter { stale.contains($0.key) }.merging(seeded) { _, new in new }
            removed = [:]
            problems = [:]
            self.rows = rows
            let inProgress = seeded[HomeRows.continueWatching.id, default: []].filter { !$0.isEpisode && $0.resumeSeconds != nil }
            featured = Self.featured(from: inProgress + seeded[HomeRows.recentMovies.id, default: []] + seeded[HomeRows.recentShows.id, default: []])
            loadError = nil
            sessionEnded = false
            hasLoaded = true
            defaults.set(seeded[HomeRows.continueWatching.id]?.isEmpty == false, forKey: continueWatchingKey)
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

    /// Swaps in a title whose watch state changed, wherever it shows. It leaves the rows it no
    /// longer fits, and Continue Watching loads again for what comes after one watched in it,
    /// such as a show's next episode. Changed back, as when the server turns the change down, it
    /// goes back where it was.
    func replace(_ item: JellyfinItem) {
        let left = withAnimation { Self.replace(item, in: &items, removed: &removed) }
        if let position = featured.firstIndex(where: { $0.id == item.id }) { featured[position] = item }
        if left.contains(HomeRows.continueWatching.id) {
            Task { await loadRow(HomeRows.continueWatching.id) }
        }
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
        queue.want(near.filter { (items[$0] == nil || stale.contains($0)) && problems[$0] == nil })
    }

    private func loadRow(_ id: HomeRow.ID) async {
        guard let session, let row = rows.first(where: { $0.id == id }) else { return }
        do {
            let page = try await session.client.page(of: row.list.source, userId: session.userId, startIndex: 0, limit: HomeRows.rowLength)
            // The server may not have the change that took a title out yet.
            let gone = removed[id] ?? [:]
            items[id] = page.items.filter { gone[$0.id] == nil }
            stale.remove(id)
        } catch {
            guard !error.isCancellation else { return }
            problems[id] = error.localizedDescription
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

    /// Up to six titles with a backdrop for the banner, each once.
    private static func featured(from candidates: [JellyfinItem]) -> [JellyfinItem] {
        var seen = Set<String>()
        return candidates.filter { $0.backdropImageTags?.isEmpty == false && seen.insert($0.id).inserted }.prefix(6).map(\.self)
    }
}
