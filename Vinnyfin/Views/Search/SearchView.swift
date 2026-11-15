import SwiftUI

/// Finds movies, shows, videos, episodes, collections, people and genres by name as you type,
/// the title most likely looked for first and the rows matching best above the rest. Each row of
/// titles samples its matches; its title opens all of them. A search that finds nothing offers
/// the name it was likely meant for. Before anything is typed, it opens on what was searched for
/// last, the libraries the tabs don't reach, and every genre to browse.
struct SearchView: View {
    #if !os(tvOS)
    /// Counts the Go menu's Search commands, each of which puts the cursor in the search field.
    var fieldRequests = 0
    /// The search field has the cursor.
    @State private var fieldIsActive = false
    #endif
    /// What Spotlight or Siri last asked to search for, which fills the search field.
    var request: SearchRequest?

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    /// What the last search to finish, or to fail, was for: what the results on screen were
    /// found for, or what `searchError` is about.
    @State private var searched = ""
    @State private var results = SearchResults()
    /// What a search that found nothing was likely meant to be.
    @State private var suggestion: String?
    /// The pages open on top of the search: titles, people, genres, and lists in full.
    @Binding var path: NavigationPath
    @State private var isSearching = false
    @State private var searchError: String?
    /// Try Again's presses, each of which searches again for the same text.
    @State private var retries = 0
    @State private var recentSearches: [String] = []
    @State private var genres = GenreTiles()
    /// The server's libraries the landing page lists.
    @State private var libraries: [JellyfinItem] = []
    /// The names of the server's titles, for `suggestion`, once a search has found nothing.
    @State private var titleNames: [String]?
    #if os(tvOS)
    /// Where the rows are, for holding the focused one in place.
    @State private var rowLayout = RowPageLayout()
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            EdgeToEdgeScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if phase == .prompt {
                        landing
                    } else {
                        if let top = results.topResult(for: searched) {
                            topResult(top)
                        }
                        ForEach(results.sections(for: searched), id: \.self) { section in
                            row(section)
                        }
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
            .alwaysSearchable(text: $text, prompt: "Titles, people and genres")
            #else
            .alwaysSearchable(text: $text, isActive: $fieldIsActive, prompt: "Titles, people and genres")
            .onChange(of: fieldRequests, initial: true) {
                if fieldRequests > 0 { fieldIsActive = true }
            }
            #endif
            .onSubmit(of: .search) { remember(SearchPhase.term(text)) }
            .onChange(of: request, initial: true) {
                if let request { text = request.term }
            }
            .itemDestinations()
            .task(id: Run(text: text, retries: retries)) { await search() }
            .task { await loadLanding() }
            // Opening something a search found keeps the search.
            .onChange(of: path.count) { before, after in
                if after > before, phase != .prompt { remember(searched) }
            }
            .onChange(of: player.endedPlayback) {
                results.update(from: player.endedPlayback)
            }
        }
        .opensTitles(on: $path)
    }

    /// A search for the text as it is; Try Again runs it again.
    private struct Run: Hashable {
        let text: String
        let retries: Int
    }

    private var phase: SearchPhase {
        SearchPhase(text: text, searched: searched, isSearching: isSearching, hasResults: !results.isEmpty, error: searchError)
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .prompt, .results:
            EmptyView()
        case .searching:
            ProgressView()
        case .noResults:
            if let suggestion {
                ContentUnavailableView {
                    Label("No Results for \u{201C}\(searched)\u{201D}", systemImage: "magnifyingglass")
                } description: {
                    Text("Did you mean \u{201C}\(suggestion)\u{201D}?")
                } actions: {
                    Button("Search for \u{201C}\(suggestion)\u{201D}") { text = suggestion }
                        .buttonStyle(.platformGlass)
                        .accessibilityIdentifier("search.didYouMean")
                }
            } else {
                ContentUnavailableView.search(text: searched)
            }
        case .failed(let message):
            LoadFailureView(LoadFailure("Search Failed", message: message), systemImage: "exclamationmark.magnifyingglass") {
                retries += 1
            }
        }
    }

    @ViewBuilder private var landing: some View {
        #if os(tvOS)
        SearchLanding(recentSearches: recentSearches, libraries: libraries, genres: genres, search: { text = $0 },
                      forget: forget, forgetAll: forgetAll, rowLayout: rowLayout)
        #else
        SearchLanding(recentSearches: recentSearches, libraries: libraries, genres: genres, search: { text = $0 },
                      forget: forget, forgetAll: forgetAll)
        #endif
    }

    private func topResult(_ item: JellyfinItem) -> some View {
        NavigationLink(value: item) { TopResultCard(item: item) }
            .buttonStyle(.artwork)
            .titleMenu(item, onChange: replace)
            .padding(.horizontal, Metrics.edge)
            #if os(tvOS)
            .focusSection()
            .pageRow("topResult", in: rowLayout)
            #endif
    }

    @ViewBuilder private func row(_ section: SearchResults.Section) -> some View {
        switch section {
        case .movies: posters("Movies", types: ["Movie"], results.movies)
        case .shows: posters("Shows", types: ["Series"], results.shows)
        case .collections: posters("Collections", types: ["BoxSet"], results.collections)
        case .videos: stills("Videos", types: BrowseList.videoTypes, results.videos)
        case .episodes: stills("Episodes", types: ["Episode"], results.episodes)
        case .people:
            Shelf(title: "People", items: results.people, cardWidth: PersonCard.width) { person in
                NavigationLink(value: person) { PersonCard(person: person) }
                    .buttonStyle(.artwork)
                    .foregroundStyle(.primary)
            }
            #if os(tvOS)
            .pageRow("People", in: rowLayout)
            #endif
        case .genres:
            VStack(alignment: .leading, spacing: 10) {
                Text("Genres")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Metrics.edge)
                GenreChips(genres: results.genres)
                    .contentMargins(.horizontal, Metrics.edge, for: .scrollContent)
            }
            #if os(tvOS)
            .pageRow("Genres", in: rowLayout)
            #endif
        }
    }

    /// Swaps in a result whose watch state changed.
    private func replace(_ item: JellyfinItem) {
        results.replace(item)
    }

    /// A row of posters of one kind: "Movies", leading to all of them.
    private func posters(_ kind: String, types: [String], _ items: [JellyfinItem]) -> some View {
        Shelf(title: kind, seeAll: list(kind, types: types), items: items, cardWidth: Metrics.posterWidth) { item in
            NavigationLink(value: item) { PosterCard(item: item) }
                .buttonStyle(.artwork)
                .titleMenu(item, onChange: replace)
        }
        #if os(tvOS)
        .pageRow(kind, in: rowLayout)
        #endif
    }

    /// A row of stills of one kind: episodes and videos, each found by its own name, which leads.
    private func stills(_ kind: String, types: [String], _ items: [JellyfinItem]) -> some View {
        Shelf(title: kind, seeAll: list(kind, types: types, style: .landscape), items: items, cardWidth: Metrics.landscapeWidth) { item in
            NavigationLink(value: item) { LandscapeCard(item: item, leadsWithEpisode: true) }
                .buttonStyle(.artwork)
                .titleMenu(item, onChange: replace)
        }
        #if os(tvOS)
        .pageRow(kind, in: rowLayout)
        #endif
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

    // MARK: Searching

    private func search() async {
        guard let session else { return }
        let term = SearchPhase.term(text)
        guard !term.isEmpty else {
            results = SearchResults()
            suggestion = nil
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
        func page(_ types: [String]) async throws -> [JellyfinItem] {
            var query = Self.query(types, term: term)
            query.limit = 24
            return try await session.client.items(userId: session.userId, query).items
        }
        do {
            async let movies = page(["Movie"])
            async let shows = page(["Series"])
            async let videos = page(BrowseList.videoTypes)
            async let episodes = page(["Episode"])
            async let hints = session.client.searchHints(userId: session.userId, term: term)
            let found = try await SearchResults(movies: movies, shows: shows, videos: videos, episodes: episodes, hints: hints)
            let meant = found.isEmpty ? await suggestion(for: term) : nil
            guard !Task.isCancelled else { return }
            // All the rows at once, with what they were found for.
            withAnimation(reduceMotion ? nil : .default) {
                results = found
                suggestion = meant
                searched = term
                searchError = nil
            }
            announce(meant.map { "No results. Did you mean \($0)?" } ?? found.summary)
        } catch {
            guard !error.isCancellation else { return }
            results = SearchResults()
            suggestion = nil
            searched = term
            searchError = error.localizedDescription
            announce("Search failed. \(error.localizedDescription)")
        }
    }

    /// The title or genre `term` was likely meant to be, from the names of every title, which the
    /// first search to find nothing loads. Without them, as when they couldn't be loaded, there's
    /// no suggestion, and the next search to find nothing asks for them again.
    private func suggestion(for term: String) async -> String? {
        if titleNames == nil, let session {
            titleNames = try? await session.client.titleNames(userId: session.userId,
                                                              types: ["Movie", "Series", "BoxSet"] + BrowseList.videoTypes)
        }
        return DidYouMean.suggestion(for: term, among: (titleNames ?? []) + (genres.genres?.map(\.name) ?? []))
    }

    // MARK: Landing page

    /// Where recent searches are kept, for whoever is signed in.
    private var recents: RecentSearches? {
        session.map { RecentSearches(serverId: $0.account.serverId, userId: $0.userId) }
    }

    private func loadLanding() async {
        guard let session else { return }
        recentSearches = recents?.load() ?? []
        async let genresLoaded: Void = genres.load(session: session)
        // Libraries the tabs reach anyway are all there are when they can't be listed.
        libraries = LibraryShortcuts.shown((try? await session.client.libraries(userId: session.userId)) ?? [])
        await genresLoaded
    }

    private func remember(_ term: String) {
        guard !term.isEmpty else { return }
        recentSearches = RecentSearches.adding(term, to: recentSearches)
        recents?.save(recentSearches)
    }

    private func forget(_ term: String) {
        recentSearches.removeAll { $0 == term }
        recents?.save(recentSearches)
    }

    private func forgetAll() {
        recentSearches = []
        recents?.save([])
    }
}

/// What Search shows over its rows, from what's typed and how the search for it is going.
/// "No Results" waits for the search for what's typed to finish: until then, as typing settles
/// or the server answers, the results of what was typed before stay, or with none, a spinner.
nonisolated enum SearchPhase: Equatable {
    /// Nothing typed yet: the landing page.
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
