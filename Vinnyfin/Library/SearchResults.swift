import Foundation

/// What a search found, by kind: titles from the server's item search, and people, genres and
/// collections from its search hints.
nonisolated struct SearchResults: Equatable, Sendable {
    /// A row of results, in the order they come when they match equally well.
    enum Section: CaseIterable, Hashable, Sendable {
        case movies, shows, collections, people, genres, videos, episodes
    }

    var movies: [JellyfinItem] = []
    var shows: [JellyfinItem] = []
    /// Home videos and music videos.
    var videos: [JellyfinItem] = []
    var episodes: [JellyfinItem] = []
    var collections: [JellyfinItem] = []
    var people: [Person] = []
    var genres: [String] = []

    init(movies: [JellyfinItem] = [], shows: [JellyfinItem] = [], videos: [JellyfinItem] = [], episodes: [JellyfinItem] = [],
         hints: [SearchHint] = []) {
        self.movies = movies
        self.shows = shows
        self.videos = videos
        self.episodes = episodes
        for hint in hints {
            switch hint.type {
            case "Person":
                people.append(Person(id: hint.id, name: hint.name, type: "Person", primaryImageTag: hint.primaryImageTag))
            case "Genre":
                if !genres.contains(hint.name) { genres.append(hint.name) }
            case "BoxSet":
                var collection = JellyfinItem(id: hint.id, name: hint.name, type: "BoxSet")
                collection.productionYear = hint.productionYear
                collection.imageTags = hint.primaryImageTag.map { ["Primary": $0] }
                collections.append(collection)
            default:
                break
            }
        }
    }

    var isEmpty: Bool {
        movies.isEmpty && shows.isEmpty && videos.isEmpty && episodes.isEmpty && collections.isEmpty && people.isEmpty && genres.isEmpty
    }

    /// The names in a row, for ranking it.
    private func names(in section: Section) -> [String] {
        switch section {
        case .movies: movies.map(\.name)
        case .shows: shows.map(\.name)
        case .collections: collections.map(\.name)
        case .people: people.map(\.name)
        case .genres: genres
        case .videos: videos.map(\.name)
        case .episodes: episodes.map(\.name)
        }
    }

    /// The rows with something in them, the one with the closest match to `term` first; rows
    /// matching equally well keep `Section`'s order: an exact show above loose movies.
    func sections(for term: String) -> [Section] {
        let ranked = Section.allCases.enumerated().compactMap { order, section -> (Section, SearchMatch, Int)? in
            let names = names(in: section)
            guard !names.isEmpty else { return nil }
            return (section, names.map { SearchMatch(name: $0, term: term) }.max() ?? .none, order)
        }
        return ranked.sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }.map(\.0)
    }

    /// The title that's most likely the one looked for, to lead the results: one named what was
    /// typed, else one whose name or a word of it starts with it, a movie, show, video or
    /// collection before an episode, then the shortest name. Nil when nothing matches that well.
    func topResult(for term: String) -> JellyfinItem? {
        let titles = movies + shows + videos + collections
        let candidates = titles.map { ($0, 1) } + episodes.map { ($0, 0) }
        let best = candidates.max { left, right in
            let leftMatch = SearchMatch(item: left.0, term: term), rightMatch = SearchMatch(item: right.0, term: term)
            if leftMatch != rightMatch { return leftMatch < rightMatch }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.0.name.count > right.0.name.count
        }
        guard let best, SearchMatch(item: best.0, term: term) >= .wordPrefix else { return nil }
        return best.0
    }

    /// Swaps in a title whose watch state changed.
    mutating func replace(_ item: JellyfinItem) {
        let swap = { (result: JellyfinItem) in result.id == item.id ? item : result }
        movies = movies.map(swap)
        shows = shows.map(swap)
        videos = videos.map(swap)
        episodes = episodes.map(swap)
        collections = collections.map(swap)
    }

    /// Puts in the watch state a playback left its titles in.
    mutating func update(from ended: EndedPlayback) {
        movies = ended.applied(to: movies)
        shows = ended.applied(to: shows)
        videos = ended.applied(to: videos)
        episodes = ended.applied(to: episodes)
    }

    /// What was found, for VoiceOver, whose cursor stays in the search field as results come in:
    /// "3 movies, 1 person and 12 episodes", or "No results".
    var summary: String {
        func count(_ number: Int, _ one: String, _ many: String) -> String? {
            number == 0 ? nil : number == 1 ? "1 \(one)" : "\(number) \(many)"
        }
        let counts = [
            count(movies.count, "movie", "movies"), count(shows.count, "show", "shows"),
            count(collections.count, "collection", "collections"), count(people.count, "person", "people"),
            count(genres.count, "genre", "genres"), count(videos.count, "video", "videos"),
            count(episodes.count, "episode", "episodes"),
        ].compactMap(\.self)
        return counts.isEmpty ? "No results" : counts.formatted(.list(type: .and))
    }
}

/// How well a name matches what was typed, ignoring case and accents, from not at all to exactly.
nonisolated enum SearchMatch: Int, Comparable, Sendable {
    case none, contains, wordPrefix, prefix, exact

    init(name: String, term: String) {
        let name = Self.normalized(name), term = Self.normalized(term)
        if term.isEmpty || name.isEmpty {
            self = .none
        } else if name == term {
            self = .exact
        } else if name.hasPrefix(term) {
            self = .prefix
        } else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(term) }) {
            self = .wordPrefix
        } else {
            self = name.contains(term) ? .contains : .none
        }
    }

    /// A title's match by its name, or by its name with its year: "Copperline (2019)".
    init(item: JellyfinItem, term: String) {
        self = max(Self(name: item.name, term: term), Self(name: item.titleWithYear, term: term) == .exact ? .exact : .none)
    }

    static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }

    /// Lowercased, without accents, and with runs of spaces and punctuation at the ends gone.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// What a search that found nothing may have meant: the name of a title or genre a letter or two
/// off what was typed, as "coperline" for Copperline. The server's search matches only names
/// that contain what's typed exactly.
nonisolated enum DidYouMean {
    /// Shorter than this, nearly every name is a letter or two off.
    static let shortestTerm = 3

    /// The closest of `names` to `term`, by the fewest letters added, taken away, changed or
    /// swapped: at most one for a term of up to five letters, two for a longer one. A long term
    /// can also be the start of a name, as "the last fery" of The Last Ferry to Ilsa. Nil when
    /// none is close enough.
    static func suggestion(for term: String, among names: [String]) -> String? {
        let typed = Array(SearchMatch.normalized(term))
        guard typed.count >= shortestTerm else { return nil }
        let allowed = typed.count <= 5 ? 1 : 2
        var best: (distance: Int, name: String)?
        for name in names {
            let candidate = Array(SearchMatch.normalized(name))
            guard !candidate.isEmpty, candidate != typed else { continue }
            var distance = editDistance(typed, candidate, limit: allowed)
            if typed.count > 5, candidate.count > typed.count {
                for length in (typed.count - 1)...min(candidate.count, typed.count + 1) {
                    distance = min(distance, editDistance(typed, Array(candidate.prefix(length)), limit: allowed))
                }
            }
            guard distance <= allowed else { continue }
            if let current = best, (current.distance, current.name.count, current.name) <= (distance, name.count, name) { continue }
            best = (distance, name)
        }
        return best?.name
    }

    /// The letters added, taken away, changed or swapped with the next that make `left` into
    /// `right`, up to `limit`; `limit + 1` for any more, which it stops counting at.
    static func editDistance(_ left: [Character], _ right: [Character], limit: Int) -> Int {
        if abs(left.count - right.count) > limit { return limit + 1 }
        if left.isEmpty || right.isEmpty { return min(max(left.count, right.count), limit + 1) }
        var before = [Int](repeating: 0, count: right.count + 1)
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, left[i - 1] == right[j - 2], left[i - 2] == right[j - 1] {
                    value = min(value, before[j - 2] + 1)
                }
                current[j] = value
                rowBest = min(rowBest, value)
            }
            if rowBest > limit { return limit + 1 }
            (before, previous, current) = (previous, current, before)
        }
        return min(previous[right.count], limit + 1)
    }
}

/// What was searched for last, most recent first, kept for each server and user.
nonisolated struct RecentSearches: @unchecked Sendable {
    static let limit = 8

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, serverId: String, userId: String) {
        self.defaults = defaults
        key = "search.recent.\(serverId).\(userId)"
    }

    func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func save(_ terms: [String]) {
        defaults.set(terms, forKey: key)
    }

    /// `terms` with `term` first, once, whatever its case was before, and no more than `limit`.
    static func adding(_ term: String, to terms: [String]) -> [String] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return terms }
        let same = SearchMatch.normalized(term)
        return Array(([term] + terms.filter { SearchMatch.normalized($0) != same }).prefix(limit))
    }
}

/// The server's libraries, on Search's landing page when the tabs don't reach each on its own:
/// a library of home videos, music videos or mixed content, which no tab lists, or a second one
/// of movies or shows, whose titles the tab lists together with the first's.
nonisolated enum LibraryShortcuts {
    static func shown(_ libraries: [JellyfinItem]) -> [JellyfinItem] {
        let kinds = libraries.map { $0.collectionType ?? "" }
        let tabsReachEach = kinds.allSatisfy { ["movies", "tvshows"].contains($0) } && Set(kinds).count == kinds.count
        return tabsReachEach ? [] : libraries
    }
}
