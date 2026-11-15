import Foundation

/// A row of Home: the list it samples, which its title opens in full.
nonisolated struct HomeRow: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let list: BrowseList
}

/// Random numbers that come out the same from the same seed (SplitMix64), so rows picked at
/// random stay put each time Home reloads, until a refresh asks for new ones.
nonisolated struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// How many titles of a kind have a genre.
nonisolated struct GenreSize: Hashable, Sendable {
    let name: String
    let count: Int
}

/// Home's rows, in order: what to watch next and what's new first; then, mixed together, rows
/// from what was watched and liked, the best and newest, and the genres watched most; and at the
/// end a row for each remaining genre big enough to fill one.
nonisolated enum HomeRows {
    /// Titles a row samples.
    static let rowLength = 20
    /// Genres with fewer titles of a kind get no row for it.
    static let minimumGenreSize = 6
    static let becauseYouWatchedCount = 3
    static let moreLikeFavoritesCount = 2

    /// Each movie partway through and each show's next episode, together (see `UpNext`).
    static let continueWatching = row("continueWatching", "Continue Watching", .upNext, style: .landscape)
    static let recentMovies = row("recentMovies", "Recently Added Movies", .items(.recentlyAddedMovies))
    static let recentShows = row("recentShows", "Recently Added Shows", .items(.recentlyAddedShows))
    static let newMovies = row("newMovies", "New Releases", .items(query(["Movie"], sortBy: "PremiereDate")))
    static let newShows = row("newShows", "New Shows", .items(query(["Series"], sortBy: "PremiereDate")))
    static let topMovies = row("topMovies", "Top Rated Movies", .items(query(["Movie"], sortBy: "CommunityRating")))
    static let topShows = row("topShows", "Top Rated Shows", .items(query(["Series"], sortBy: "CommunityRating")))
    static let favorites = row("favorites", "Favorites", .items(query(["Movie", "Series"], sortBy: "SortName", ascending: true) {
        $0.isFavorite = true
    }))
    static let unwatchedFavorites = row("unwatchedFavorites", "Unwatched Favorites", .items(query(["Movie", "Series"], sortBy: "SortName", ascending: true) {
        $0.isFavorite = true
        $0.isPlayed = false
    }))
    static let collections = row("collections", "Collections", .items(query(["BoxSet"], sortBy: "SortName", ascending: true)))
    static let recentlyWatched = row("recentlyWatched", "Recently Watched", .items(query(["Movie", "Episode"], sortBy: "DatePlayed") {
        $0.isPlayed = true
    }), style: .landscape)

    /// The rows Home always starts with, filled by its first round of requests.
    static let leading = [continueWatching, recentMovies, recentShows]

    /// What stands in for `leading` until the first round of requests comes back: Continue
    /// Watching only when it had something in it last time, as it's most often empty for good.
    static func placeholders(continueWatching hadItems: Bool) -> [HomeRow] {
        hadItems ? leading : leading.filter { $0 != continueWatching }
    }

    static func becauseYouWatched(_ title: JellyfinItem) -> HomeRow {
        row("becauseYouWatched.\(title.id)", "Because You Watched \(title.name)", .similar(toItemId: title.id))
    }

    static func moreLike(_ favorite: JellyfinItem) -> HomeRow {
        row("moreLike.\(favorite.id)", "More Like \(favorite.name)", .similar(toItemId: favorite.id))
    }

    /// The best of a genre, for movies or for shows.
    static func genre(_ name: String, type: String) -> HomeRow {
        row("genre.\(type).\(name)", "\(name) \(type == "Movie" ? "Movies" : "Shows")", .items(query([type], sortBy: "CommunityRating") {
            $0.genres = [name]
        }))
    }

    /// The best of a genre nothing has been watched or started of, movies and shows together.
    static func somethingDifferent(_ genre: String) -> HomeRow {
        row("somethingDifferent.\(genre)", "Something Different: \(genre)", .items(query(["Movie", "Series"], sortBy: "CommunityRating") {
            $0.genres = [genre]
            $0.isPlayed = false
        }))
    }

    /// Whether `item` belongs in the row `id` by the row's own rule, after its watch state changed:
    /// Continue Watching holds nothing watched, and the favorites rows nothing that isn't one, or
    /// for Unwatched Favorites, that's been watched. Other rows hold a title whatever its state.
    static func fits(_ item: JellyfinItem, in id: HomeRow.ID) -> Bool {
        switch id {
        case continueWatching.id: !item.isPlayed
        case favorites.id: item.isFavorite
        case unwatchedFavorites.id: item.isFavorite && !item.isPlayed
        default: true
        }
    }

    // MARK: Curation

    /// Rows made from one title or one genre with fewer titles than this aren't worth a row.
    static let minimumMadeRowSize = 4
    /// How many of a row's first titles tell whether it repeats the rows above it: about what
    /// shows of it without scrolling.
    static let repeatWindow = 10
    /// The share of those that, already in the rows above, makes a row a repeat.
    static let repeatShare = 0.8

    /// Whether a row shows whatever it holds: what to watch next, what's newest, the favorites
    /// picked and what was watched. Every other row is picked for Home, and gives way when it
    /// has too little in it or repeats the rows above it.
    static func isKept(_ id: HomeRow.ID) -> Bool {
        [continueWatching.id, recentMovies.id, recentShows.id, favorites.id, recentlyWatched.id].contains(id)
    }

    /// Whether a row is made from one title or one genre: the titles like one watched or
    /// favorited, and a genre's best.
    static func isMadeRow(_ id: HomeRow.ID) -> Bool {
        ["becauseYouWatched.", "moreLike.", "genre.", "somethingDifferent."].contains { id.hasPrefix($0) }
    }

    /// Whether the row `id`, loaded with `titles`, gives way, under the rows shown above it with
    /// `above`: a row made from one title or genre with fewer than `minimumMadeRowSize` titles,
    /// or any row picked for Home most of whose first titles are already above, as Unwatched
    /// Favorites with nothing watched is Favorites again, and in a small library New Releases
    /// and Top Rated are Recently Added again.
    static func givesWay(_ id: HomeRow.ID, titles: [JellyfinItem], above: [[JellyfinItem]]) -> Bool {
        guard !isKept(id), !titles.isEmpty else { return false }
        if isMadeRow(id), titles.count < minimumMadeRowSize { return true }
        let shown = Set(above.joined().map(\.id))
        let first = titles.prefix(repeatWindow)
        let repeated = first.count { shown.contains($0.id) }
        return Double(repeated) >= repeatShare * Double(first.count)
    }

    // MARK: Featured titles

    /// How many titles the banner turns through.
    static let featuredCount = 6
    /// With fewer new titles than this to feature, the best rated fill in.
    static let featuredMinimum = 3

    /// The banner's titles, up to `featuredCount`: the newest movies and shows not watched or
    /// started, in turn, those with a logo before those without, then the best rated of those
    /// when there are fewer than `featuredMinimum`. None is in Continue Watching, which is right
    /// under the banner. Only a library with nothing else features what was watched. Each needs
    /// a backdrop to show.
    static func featured(movies: [JellyfinItem], shows: [JellyfinItem], topRated: [JellyfinItem] = [],
                         continueWatching: [JellyfinItem]) -> [JellyfinItem] {
        let watching = Set(continueWatching.map(\.titleId))
        let showable = { (item: JellyfinItem) in item.backdropImageTags?.isEmpty == false && !watching.contains(item.titleId) }
        func fresh(_ items: [JellyfinItem]) -> [JellyfinItem] {
            let unseen = items.filter { showable($0) && !isStarted($0) }
            return unseen.filter(hasLogo) + unseen.filter { !hasLogo($0) }
        }
        var picked = alternating(fresh(movies), fresh(shows))
        if picked.count < featuredMinimum { picked += fresh(topRated) }
        if picked.isEmpty { picked = (movies + shows + topRated).filter(showable) }
        var seen = Set<String>()
        return Array(picked.filter { seen.insert($0.id).inserted }.prefix(featuredCount))
    }

    /// Watched, or partway through: a show any of whose episodes were watched.
    static func isStarted(_ item: JellyfinItem) -> Bool {
        if item.isPlayed || item.resumeSeconds != nil { return true }
        return item.isSeries && (item.userData?.playedPercentage ?? 0) > 0
    }

    private static func hasLogo(_ item: JellyfinItem) -> Bool {
        item.imageTags?["Logo"] != nil
    }

    /// One from each in turn, then the rest of the longer.
    private static func alternating(_ first: [JellyfinItem], _ second: [JellyfinItem]) -> [JellyfinItem] {
        var result: [JellyfinItem] = []
        for index in 0..<max(first.count, second.count) {
            if index < first.count { result.append(first[index]) }
            if index < second.count { result.append(second[index]) }
        }
        return result
    }

    /// The best rated movies and shows not yet watched, for the banner when there are too few new.
    static let topRatedUnwatched = row("topRatedUnwatched", "Top Rated", .items(query(["Movie", "Series"], sortBy: "CommunityRating") {
        $0.isPlayed = false
    }))

    /// What the rows are made from.
    struct Inputs: Sendable {
        /// Movies and shows watched, newest first, with their genres.
        var watched: [JellyfinItem] = []
        /// Movies and shows started or in Continue Watching, with their genres.
        var started: [JellyfinItem] = []
        var favorites: [JellyfinItem] = []
        var movieGenres: [GenreSize] = []
        var showGenres: [GenreSize] = []
    }

    static func assemble(_ inputs: Inputs, using random: inout some RandomNumberGenerator) -> [HomeRow] {
        let anchors = inputs.watched.prefix(becauseYouWatchedCount)
        let anchorIds = Set(anchors.map(\.id))
        var becauseRows = anchors.map(becauseYouWatched)
        var favoriteRows = inputs.favorites.filter { !anchorIds.contains($0.id) }.shuffled(using: &random)
            .prefix(moreLikeFavoritesCount).map(moreLike)
        var genreRows = rankedGenres(inputs).map { genre($0.name, type: $0.type) }
        let different = differentGenre(inputs, using: &random).map(somethingDifferent)

        var rows = leading
        func take(_ queue: inout [HomeRow]) {
            if !queue.isEmpty { rows.append(queue.removeFirst()) }
        }
        take(&becauseRows)
        take(&genreRows)
        rows.append(newMovies)
        take(&becauseRows)
        take(&genreRows)
        rows.append(topMovies)
        if !inputs.favorites.isEmpty { rows.append(favorites) }
        take(&becauseRows)
        take(&genreRows)
        rows += [newShows, topShows]
        take(&favoriteRows)
        if !inputs.favorites.isEmpty { rows.append(unwatchedFavorites) }
        if let different { rows.append(different) }
        take(&genreRows)
        rows.append(collections)
        take(&favoriteRows)
        rows.append(recentlyWatched)
        return rows + genreRows
    }

    /// Every genre big enough for a row, for movies and for shows: those of the most titles
    /// watched first, then the biggest.
    static func rankedGenres(_ inputs: Inputs) -> [(name: String, type: String)] {
        let affinity = affinity(of: inputs.watched)
        let candidates = inputs.movieGenres.map { ($0, "Movie") } + inputs.showGenres.map { ($0, "Series") }
        return candidates
            .filter { $0.0.count >= minimumGenreSize }
            .sorted { left, right in
                let leftScore = affinity[left.0.name, default: 0], rightScore = affinity[right.0.name, default: 0]
                if leftScore != rightScore { return leftScore > rightScore }
                if left.0.count != right.0.count { return left.0.count > right.0.count }
                return (left.0.name, left.1) < (right.0.name, right.1)
            }
            .map { (name: $0.0.name, type: $0.1) }
    }

    /// A genre, picked at random among those big enough for a row, that nothing watched, started
    /// or in Continue Watching has, so the row holds none of those either. Without anything
    /// watched yet, every genre would be different, and there's no row.
    static func differentGenre(_ inputs: Inputs, using random: inout some RandomNumberGenerator) -> String? {
        guard !inputs.watched.isEmpty else { return nil }
        let affinity = affinity(of: inputs.watched + inputs.started)
        var sizes: [String: Int] = [:]
        for genre in inputs.movieGenres + inputs.showGenres { sizes[genre.name, default: 0] += genre.count }
        let candidates = sizes.filter { $0.value >= minimumGenreSize && affinity[$0.key, default: 0] == 0 }.keys.sorted()
        return candidates.randomElement(using: &random)
    }

    /// How many of the titles watched have each genre.
    static func affinity(of watched: [JellyfinItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for title in watched {
            for genre in Set(title.genres ?? []) { counts[genre, default: 0] += 1 }
        }
        return counts
    }

    /// The movies and shows behind what was played, newest first and each once: an episode
    /// stands for its show, looked up in `shows`.
    static func titles(played: [JellyfinItem], shows: [JellyfinItem]) -> [JellyfinItem] {
        let showsById = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return played.compactMap { item in
            let title = item.isEpisode ? showsById[item.titleId] : item
            guard let title, seen.insert(title.id).inserted else { return nil }
            return title
        }
    }

    private static func row(_ id: String, _ title: String, _ source: JellyfinClient.ItemSource,
                            style: BrowseList.Style = .poster) -> HomeRow {
        HomeRow(id: id, list: BrowseList(title: title, source: source, style: style))
    }

    /// A row's query: newest, best or last first unless `ascending`.
    private static func query(_ types: [String], sortBy: String, ascending: Bool = false,
                              _ refine: (inout JellyfinClient.ItemQuery) -> Void = { _ in }) -> JellyfinClient.ItemQuery {
        var query = JellyfinClient.ItemQuery(types: types)
        query.sortBy = sortBy
        query.ascending = ascending
        query.fields = JellyfinClient.cardFields
        refine(&query)
        return query
    }
}
