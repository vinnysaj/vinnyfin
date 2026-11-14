import Foundation

extension LibraryGridView {
    /// An order the grid's menu offers.
    nonisolated enum Sort: String, CaseIterable, Identifiable, Codable, Sendable {
        case name, dateAdded, releaseDate, rating, lastPlayed, random

        var id: Self { self }

        var label: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Date Added"
            case .releaseDate: "Release Date"
            case .rating: "Rating"
            case .lastPlayed: "Recently Watched"
            case .random: "Random"
            }
        }

        /// The server's field for it; nil for random, which is shuffled here (see `ShuffleOrder`),
        /// as the server's own random order is a new one for each page. A show counts as added when
        /// an episode last was.
        func serverField(for types: [String]) -> String? {
            switch self {
            case .name: "SortName"
            case .dateAdded: types == ["Series"] ? "DateLastContentAdded" : "DateCreated"
            case .releaseDate: "PremiereDate"
            case .rating: "CommunityRating"
            case .lastPlayed: "DatePlayed"
            case .random: nil
            }
        }

        /// The sort a query is in, if it's one of these.
        init?(_ query: JellyfinClient.ItemQuery) {
            guard let sort = Self.allCases.first(where: { $0.serverField(for: query.types) == query.sortBy }) else { return nil }
            self = sort
        }

        /// The way it goes when it's chosen: names from A, everything else the latest or best first.
        var startsAscending: Bool { self == .name }

        /// Each way it can go, in words: "A to Z", "Newest First". Nil for random, which goes neither way.
        func direction(ascending: Bool) -> String? {
            switch self {
            case .name: ascending ? "A to Z" : "Z to A"
            case .dateAdded, .releaseDate: ascending ? "Oldest First" : "Newest First"
            case .rating: ascending ? "Lowest First" : "Highest First"
            case .lastPlayed: ascending ? "Earliest First" : "Latest First"
            case .random: nil
            }
        }
    }

    /// Which of a list's titles the grid's menu shows by watch state.
    nonisolated enum Filter: String, CaseIterable, Identifiable, Codable, Sendable {
        case all, unwatched, favorites

        var id: Self { self }

        var label: String {
            switch self {
            case .all: "All"
            case .unwatched: "Unwatched"
            case .favorites: "Favorites"
            }
        }
    }
}

/// How the grid's menu and chips have refined a list: its order, and what they narrow it to
/// beyond what the list does itself. The list's own query stays as it is, the base each
/// refinement applies to, so taking a filter away gives back the list's.
nonisolated struct LibraryRefinements: Codable, Hashable, Sendable {
    typealias Sort = LibraryGridView.Sort
    typealias Filter = LibraryGridView.Filter

    /// Nil keeps the list's own order, when it's none of the menu's.
    var sort: Sort?
    var ascending: Bool
    var filter = Filter.all
    /// Titles of any of these genres.
    var genres: [String] = []
    /// One of the server's libraries.
    var libraryId: String?

    /// None: the list as it comes, in its own order.
    init(of base: JellyfinClient.ItemQuery) {
        sort = Sort(base)
        ascending = base.ascending
    }

    init(sort: Sort?, ascending: Bool, filter: Filter = .all, genres: [String] = [], libraryId: String? = nil) {
        self.sort = sort
        self.ascending = ascending
        self.filter = filter
        self.genres = genres
        self.libraryId = libraryId
    }

    /// The list's query refined. The list's own filters win over the menu's, which doesn't offer
    /// what the list fixes.
    func applied(to base: JellyfinClient.ItemQuery) -> JellyfinClient.ItemQuery {
        var query = base
        if let sort, let field = sort.serverField(for: base.types) {
            query.sortBy = field
            query.ascending = ascending
        }
        if filtersWatchState(of: base) {
            query.isPlayed = filter == .unwatched ? false : nil
            query.isFavorite = filter == .favorites ? true : nil
        }
        if base.genres.isEmpty { query.genres = genres }
        if base.parentId == nil, let libraryId { query.parentId = libraryId }
        return query
    }

    /// Whether the menu can filter the list by watch state: the list doesn't already.
    private func filtersWatchState(of base: JellyfinClient.ItemQuery) -> Bool {
        base.isPlayed == nil && base.isFavorite == nil
    }

    /// Where the list's titles come from, refined: shuffled by `seed` when the sort is random.
    func source(for base: JellyfinClient.ItemQuery, seed: UInt64) -> JellyfinClient.ItemSource {
        let query = applied(to: base)
        return sort == .random ? .shuffled(query, seed: seed) : .items(query)
    }

    /// Chooses a sort, going its usual way.
    mutating func choose(_ sort: Sort) {
        self.sort = sort
        ascending = sort.startsAscending
    }

    /// The sort and the way it goes, as the sort chip says it: "Name, A to Z", "Random".
    var sortSummary: String? {
        guard let sort else { return nil }
        return [sort.label, sort.direction(ascending: ascending)].compactMap(\.self).joined(separator: ", ")
    }

    // MARK: Filters

    /// One way the list is narrowed, which its chip takes away.
    enum Chip: Hashable, Sendable, Identifiable {
        case filter(Filter)
        case genre(String)
        case library(id: String, name: String)

        var id: Self { self }

        var label: String {
            switch self {
            case .filter(let filter): filter.label
            case .genre(let genre): genre
            case .library(_, let name): name
            }
        }
    }

    /// A chip for each way the list is narrowed: by watch state, by each genre, by a library,
    /// named from `libraries`.
    func chips(libraries: [JellyfinItem]) -> [Chip] {
        var chips: [Chip] = []
        if filter != .all { chips.append(.filter(filter)) }
        chips += genres.map(Chip.genre)
        if let libraryId {
            chips.append(.library(id: libraryId, name: libraries.first { $0.id == libraryId }?.name ?? "Library"))
        }
        return chips
    }

    /// Whether anything narrows the list.
    var isFiltered: Bool { filter != .all || !genres.isEmpty || libraryId != nil }

    /// Takes away what a chip stands for.
    mutating func remove(_ chip: Chip) {
        switch chip {
        case .filter: filter = .all
        case .genre(let genre): genres.removeAll { $0 == genre }
        case .library: libraryId = nil
        }
    }

    /// Takes away every filter, leaving the sort.
    mutating func clearFilters() {
        filter = .all
        genres = []
        libraryId = nil
    }

    /// Picks a genre, or puts it back, keeping the rest in the order they were picked.
    mutating func toggle(genre: String) {
        if genres.contains(genre) {
            genres.removeAll { $0 == genre }
        } else {
            genres.append(genre)
        }
    }

    /// The filters as they read in a sentence: "Favorites and Drama or Thriller".
    func filterSummary(libraries: [JellyfinItem]) -> String {
        filterParts(libraries: libraries).formatted(.list(type: .and))
    }

    /// The filters as a line under the list's title: "Favorites · Drama or Thriller".
    func filterSubtitle(libraries: [JellyfinItem]) -> String {
        filterParts(libraries: libraries).joined(separator: " · ")
    }

    private func filterParts(libraries: [JellyfinItem]) -> [String] {
        var parts: [String] = []
        if filter != .all { parts.append(filter.label) }
        if !genres.isEmpty { parts.append(genres.formatted(.list(type: .or))) }
        for case .library(_, let name) in chips(libraries: libraries) { parts.append(name) }
        return parts
    }
}

/// Where the Movies and Shows tabs keep their sort and filter from one launch to the next, for
/// each server and user: the genres and libraries a filter names are that server's.
nonisolated struct LibraryMemory: @unchecked Sendable {
    let defaults: UserDefaults
    /// The list's `BrowseList.refinementsKey`, with the sign-in's server and user.
    let key: String

    init(defaults: UserDefaults = .standard, list: String, serverId: String, userId: String) {
        self.defaults = defaults
        key = "library.refinements.\(list).\(serverId).\(userId)"
    }

    /// What was kept, or nil when nothing was or it can't be read.
    func load() -> LibraryRefinements? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LibraryRefinements.self, from: $0) }
    }

    func save(_ refinements: LibraryRefinements) {
        guard let data = try? JSONEncoder().encode(refinements) else { return }
        defaults.set(data, forKey: key)
    }
}
