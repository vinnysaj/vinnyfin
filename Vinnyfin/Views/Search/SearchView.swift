import SwiftUI

/// Finds movies, shows and episodes by name as you type. Each row samples its matches; its title
/// opens all of them.
struct SearchView: View {
    #if !os(tvOS)
    /// Counts the Go menu's Search commands, each of which puts the cursor in the search field.
    var fieldRequests = 0
    /// The search field has the cursor.
    @State private var fieldIsActive = false
    #endif

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    /// What the last search to finish, or to fail, was for: what the results on screen were
    /// found for, or what `searchError` is about.
    @State private var searched = ""
    @State private var movies: [JellyfinItem] = []
    @State private var shows: [JellyfinItem] = []
    @State private var episodes: [JellyfinItem] = []
    /// The pages open on top of the search: titles, and lists in full.
    @Binding var path: NavigationPath
    @State private var isSearching = false
    @State private var searchError: String?
    /// Try Again's presses, each of which searches again for the same text.
    @State private var retries = 0
    #if os(tvOS)
    /// Where the rows are, for holding the focused one in place.
    @State private var rowLayout = RowPageLayout()
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            EdgeToEdgeScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    results("Movies", types: ["Movie"], movies)
                    results("Shows", types: ["Series"], shows)
                    if !episodes.isEmpty {
                        Shelf(title: "Episodes", seeAll: list("Episodes", types: ["Episode"], style: .landscape),
                              items: episodes, cardWidth: Metrics.landscapeWidth) { item in
                            // Found by its own name, which leads.
                            NavigationLink(value: item) { LandscapeCard(item: item, leadsWithEpisode: true) }
                                .buttonStyle(.artwork)
                                .titleMenu(item, onChange: replace)
                        }
                        #if os(tvOS)
                        .pageRow("Episodes", in: rowLayout)
                        #endif
                    }
                }
                #if os(tvOS)
                .rowPageContent(rowLayout)
                #endif
                .padding(.vertical, Metrics.edge)
            }
            #if os(tvOS)
            .rowPage(rowLayout)
            #elseif os(iOS) || os(macOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .overlay { status }
            .pageBackground()
            .screenTitle("Search")
            #if os(tvOS)
            .alwaysSearchable(text: $text, prompt: "Movies, shows and episodes")
            #else
            .alwaysSearchable(text: $text, isActive: $fieldIsActive, prompt: "Movies, shows and episodes")
            .onChange(of: fieldRequests, initial: true) {
                if fieldRequests > 0 { fieldIsActive = true }
            }
            #endif
            .itemDestinations()
            .task(id: Run(text: text, retries: retries)) { await search() }
            .onChange(of: player.endedPlayback) {
                let ended = player.endedPlayback
                movies = ended.applied(to: movies)
                shows = ended.applied(to: shows)
                episodes = ended.applied(to: episodes)
            }
        }
        .opensTitles(on: $path)
    }

    /// A search for the text as it is; Try Again runs it again.
    private struct Run: Hashable {
        let text: String
        let retries: Int
    }

    @ViewBuilder private var status: some View {
        switch SearchPhase(text: text, searched: searched, isSearching: isSearching,
                           hasResults: !movies.isEmpty || !shows.isEmpty || !episodes.isEmpty, error: searchError) {
        case .prompt:
            ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                   description: Text("Find movies, shows and episodes by name."))
        case .searching:
            ProgressView()
        case .results:
            EmptyView()
        case .noResults:
            ContentUnavailableView.search(text: searched)
        case .failed(let message):
            LoadFailureView(LoadFailure("Search Failed", message: message), systemImage: "exclamationmark.magnifyingglass") {
                retries += 1
            }
        }
    }

    /// What was found, for VoiceOver, whose cursor stays in the search field as results come in:
    /// "3 movies, 1 show and 12 episodes", or "No results".
    private var resultsSummary: String {
        func count(_ found: [JellyfinItem], _ one: String, _ many: String) -> String? {
            found.isEmpty ? nil : found.count == 1 ? "1 \(one)" : "\(found.count) \(many)"
        }
        let counts = [count(movies, "movie", "movies"), count(shows, "show", "shows"), count(episodes, "episode", "episodes")]
            .compactMap(\.self)
        return counts.isEmpty ? "No results" : counts.formatted(.list(type: .and))
    }

    /// Swaps in a result whose watch state changed.
    private func replace(_ item: JellyfinItem) {
        let swap = { (result: JellyfinItem) in result.id == item.id ? item : result }
        movies = movies.map(swap)
        shows = shows.map(swap)
        episodes = episodes.map(swap)
    }

    /// A row of posters of one kind: "Movies", leading to all of them.
    @ViewBuilder private func results(_ kind: String, types: [String], _ items: [JellyfinItem]) -> some View {
        if !items.isEmpty {
            Shelf(title: kind, seeAll: list(kind, types: types), items: items, cardWidth: Metrics.posterWidth) { item in
                NavigationLink(value: item) { PosterCard(item: item) }
                    .buttonStyle(.artwork)
                    .titleMenu(item, onChange: replace)
            }
            #if os(tvOS)
            .pageRow(kind, in: rowLayout)
            #endif
        }
    }

    /// Every match of one kind, for the row's title to open.
    private func list(_ kind: String, types: [String], style: BrowseList.Style = .poster) -> BrowseList {
        BrowseList(title: Self.seeAllTitle(kind, term: searched), source: .items(Self.query(types, term: searched)), style: style)
    }

    /// The title of every match of a kind: "Movies Matching “ferry”".
    nonisolated static func seeAllTitle(_ kind: String, term: String) -> String {
        "\(kind) Matching \u{201C}\(term)\u{201D}"
    }

    private static func query(_ types: [String], term: String) -> JellyfinClient.ItemQuery {
        var query = JellyfinClient.ItemQuery(types: types)
        query.searchTerm = term
        query.fields = JellyfinClient.cardFields
        return query
    }

    private func search() async {
        guard let session else { return }
        let term = SearchPhase.term(text)
        guard !term.isEmpty else {
            movies = []
            shows = []
            episodes = []
            searched = ""
            searchError = nil
            return
        }
        // Wait for typing to settle; a newer search cancels this one.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        isSearching = true
        defer { isSearching = false }
        func page(_ types: [String]) -> JellyfinClient.ItemQuery {
            var query = Self.query(types, term: term)
            query.limit = 24
            return query
        }
        do {
            async let movies = session.client.items(userId: session.userId, page(["Movie"]))
            async let shows = session.client.items(userId: session.userId, page(["Series"]))
            async let episodes = session.client.items(userId: session.userId, page(["Episode"]))
            let found = try await (movies, shows, episodes)
            // All the rows at once, with what they were found for.
            withAnimation(reduceMotion ? nil : .default) {
                self.movies = found.0.items
                self.shows = found.1.items
                self.episodes = found.2.items
                searched = term
                searchError = nil
            }
            announce(resultsSummary)
        } catch {
            guard !error.isCancellation else { return }
            self.movies = []
            self.shows = []
            self.episodes = []
            searched = term
            searchError = error.localizedDescription
            announce("Search failed. \(error.localizedDescription)")
        }
    }
}

/// What Search shows over its rows, from what's typed and how the search for it is going.
/// "No Results" waits for the search for what's typed to finish: until then, as typing settles
/// or the server answers, the results of what was typed before stay, or with none, a spinner.
nonisolated enum SearchPhase: Equatable {
    /// Nothing typed yet: what Search finds.
    case prompt
    /// Waiting on the search for what's typed, with nothing to show meanwhile.
    case searching
    /// Rows of what was found.
    case results
    /// Nothing matches what's typed.
    case noResults
    /// The search for what's typed failed, and why.
    case failed(String)

    /// `searched` is what the last search to finish or fail was for; `isSearching`, whether one
    /// is waiting on the server; `hasResults`, whether there are rows to show; and `error`, why
    /// the last search failed.
    init(text: String, searched: String, isSearching: Bool, hasResults: Bool, error: String?) {
        let term = Self.term(text)
        let isSettled = searched == term && !isSearching
        if term.isEmpty {
            self = .prompt
        } else if isSettled, let error {
            self = .failed(error)
        } else if hasResults {
            self = .results
        } else {
            self = isSettled ? .noResults : .searching
        }
    }

    /// What's searched for when `text` is typed.
    static func term(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}
