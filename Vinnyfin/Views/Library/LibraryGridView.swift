import SwiftUI

/// A list in full, as a grid of cards: every movie or show, or everything a Home row samples.
/// It loads a page at a time around what's on screen, so it opens at once and scrolls the same
/// at any length. Sorted by name it has an A–Z index down the leading side. Coming back to it,
/// from a title's page or another tab, it's where it was left, refreshed in place.
struct LibraryGridView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case name, dateAdded, releaseDate, rating, lastPlayed

        var id: Self { self }
        var label: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Date Added"
            case .releaseDate: "Release Date"
            case .rating: "Rating"
            case .lastPlayed: "Recently Watched"
            }
        }

        /// The server's field for it. A show counts as added when an episode last was.
        func serverField(for types: [String]) -> String {
            switch self {
            case .name: "SortName"
            case .dateAdded: types == ["Series"] ? "DateLastContentAdded" : "DateCreated"
            case .releaseDate: "PremiereDate"
            case .rating: "CommunityRating"
            case .lastPlayed: "DatePlayed"
            }
        }

        /// The sort a query uses, if it's one of these.
        init?(_ query: JellyfinClient.ItemQuery) {
            guard let sort = Self.allCases.first(where: { $0.serverField(for: query.types) == query.sortBy }) else { return nil }
            self = sort
        }

        func apply(to query: inout JellyfinClient.ItemQuery) {
            query.sortBy = serverField(for: query.types)
            query.ascending = self == .name
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, unwatched, favorites
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .unwatched: "Unwatched"
            case .favorites: "Favorites"
            }
        }

        init(_ query: JellyfinClient.ItemQuery) {
            self = query.isFavorite == true ? .favorites : query.isPlayed == false ? .unwatched : .all
        }

        func apply(to query: inout JellyfinClient.ItemQuery) {
            query.isPlayed = self == .unwatched ? false : nil
            query.isFavorite = self == .favorites ? true : nil
        }
    }

    let list: BrowseList

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.cardScale) private var cardScale
    /// The list's query as the menu has changed it; nil for a list that isn't a query.
    @State private var query: JellyfinClient.ItemQuery?
    @State private var items: PagedItems?
    @State private var refreshProblem: String?
    @State private var genres: [String] = []
    @State private var libraries: [JellyfinItem] = []
    @State private var filterProblem: String?
    /// The position at the top of the screen, kept there when the columns change with the width:
    /// a rotation, an unfold, a resized window.
    @State private var position = ScrollPosition(idType: Int.self)
    /// The jump to the letter last chosen; choosing another replaces it.
    @State private var jumping: Task<Void, Never>?
    @FocusState private var focusedIndex: Int?
    /// The grid's width, once it's known, which says how many columns it has.
    @State private var gridWidth: CGFloat?
    #if os(tvOS)
    /// Opened from another screen rather than as a tab's first.
    @Environment(\.isPresented) private var isPresented
    @State private var pendingFocus: Int?
    /// The positions the grid holds.
    @State private var focusWindow = FocusWindow()
    /// The index's letter for the title focus was last on in the grid.
    @State private var focusedLetter: String?
    #endif

    init(list: BrowseList) {
        self.list = list
        _query = State(initialValue: Self.query(of: list))
    }

    private static func query(of list: BrowseList) -> JellyfinClient.ItemQuery? {
        guard case .items(var query) = list.source else { return nil }
        query.fields = JellyfinClient.cardFields
        return query
    }

    /// The list's own query, which the menu refines but whose filters it leaves alone.
    private var base: JellyfinClient.ItemQuery? { Self.query(of: list) }
    private var source: JellyfinClient.ItemSource { query.map { .items($0) } ?? list.source }
    private var showsIndex: Bool { items?.isSortedByName == true && (items?.count ?? 0) > 30 }

    var body: some View {
        EdgeToEdgeScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let columnCount {
                    if let items, let count = items.count {
                        grid(items, count: count, columns: columnCount)
                    } else if items?.problem == nil {
                        // The shapes of the first titles while the list starts loading.
                        placeholders(columns: columnCount)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .padding(.leading, leadingMargin)
            .padding(.trailing, Metrics.edge)
            .padding(.bottom, Metrics.edge)
        }
        .scrollPosition($position, anchor: .top)
        #if os(tvOS)
        .scrollTargetBehavior(VerticalScrollBehavior())
        .onScrollPhaseChange { _, phase in
            if phase == .idle, let index = focusedIndex, let columnCount, let count = items?.count {
                focusWindow.follow(index, count: count, columns: columnCount)
            }
        }
        .onChange(of: focusedIndex) { _, index in
            guard let index, let letter = items?.index?.letter(at: index), letter != focusedLetter else { return }
            focusedLetter = letter
        }
        #endif
        // A new sort or filter starts at the top.
        .id(source)
        .overlay(alignment: .leading) {
            if showsIndex, let items {
                // Every letter is live until the server's counts say which have titles.
                AlphabetIndex(available: items.index.map { Set($0.sections.map(\.letter)) } ?? Set(LibraryIndex.alphabet),
                              current: currentLetter) { letter in
                    jump(to: letter, in: items)
                }
                .padding(.vertical, 12)
                .padding(.top, indexTopInset)
                .padding(.leading, indexInset)
            }
        }
        .overlay { status }
        .overlay(alignment: .bottom) { pageProblem }
        .pageBackground()
        .screenTitle(title)
        #if !os(tvOS)
        .toolbar {
            if query != nil {
                ToolbarItem(placement: .primaryAction) { sortAndFilter }
            }
        }
        #endif
        // Run again each time the grid comes back on screen. Only a new sort or filter starts
        // over; the same list is loaded again behind the one showing and swapped in where it
        // is, with what changed on a title's page meanwhile, as its watch state.
        .task(id: source) {
            if let items, items.source == source {
                await load(startingOver: false, keepingIndex: true)
            } else {
                await load(startingOver: true)
            }
        }
        .onChange(of: player.endedPlayback) { items?.update(from: player.endedPlayback) }
        .task { await loadFilters() }
        .refreshable { await load(startingOver: false) }
    }

    @ViewBuilder private var status: some View {
        if let items, items.count == nil, let problem = items.problem {
            LoadFailureView(LoadFailure("Couldn't Load \(title)", message: problem)) {
                Task { await load(startingOver: true) }
            }
        } else if items?.count == 0 {
            if isFiltered {
                ContentUnavailableView {
                    Label("No Matches", systemImage: list.symbol)
                } description: {
                    Text("Nothing in \(title) matches \(filterSummary).")
                } actions: {
                    Button("Clear Filters", action: clearFilters)
                        .buttonStyle(.platformGlass)
                        .accessibilityIdentifier("library.clearFilters")
                }
            } else {
                ContentUnavailableView("No \(title)", systemImage: list.symbol, description: Text("Nothing here yet."))
            }
        }
    }

    /// A page, or a refresh, that failed while the list is showing.
    @ViewBuilder private var pageProblem: some View {
        if let items, items.count != nil, let problem = items.problem ?? refreshProblem {
            HStack(spacing: 12) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .lineLimit(2)
                Button("Try Again") {
                    refreshProblem = nil
                    items.retry()
                }
                .buttonStyle(.platformGlassProminent)
            }
            .padding(12)
            .platformGlass(in: .capsule)
            .padding(.horizontal, Metrics.edge)
            .padding(.bottom, Metrics.edge)
        }
    }

    /// Room above the index for Apple TV's toolbar, which floats over the grid.
    private var indexTopInset: CGFloat {
        #if os(tvOS)
        120
        #else
        0
        #endif
    }

    /// The index's distance from the screen's edge: on Apple TV, inside the overscan margin.
    /// Elsewhere its strip, wider than its letters, starts at the edge.
    private var indexInset: CGFloat {
        #if os(tvOS)
        Metrics.edge
        #else
        0
        #endif
    }

    /// The grid's leading margin, which with the index leaves room for it.
    private var leadingMargin: CGFloat {
        guard showsIndex else { return Metrics.edge }
        #if os(tvOS)
        return indexInset + AlphabetIndex.width + Metrics.edge
        #else
        return AlphabetIndex.touchWidth
        #endif
    }

    /// On Apple TV, the letter focus comes into the index at: that of the title it was last on.
    private var currentLetter: String? {
        #if os(tvOS)
        focusedLetter
        #else
        nil
        #endif
    }

    /// The width a card aims for here: larger on a regular-width screen and at the accessibility
    /// text sizes.
    private var cardWidth: CGFloat { dynamicTypeSize.cardWidth(list.style.cardWidth * cardScale) }

    /// The grid's columns, once its width is known: as many as fit at a card's width or wider,
    /// filling the width, so the margins either side stay even. On Apple TV, whole rows leave
    /// the focus window as it moves and the rest stay put.
    private var columnCount: Int? {
        gridWidth.map { CardFit.columns(in: $0, minimum: cardWidth, spacing: Metrics.gridSpacing) }
    }

    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top), count: count)
    }

    /// One flat grid at any sort: letters don't head sections, since where each starts is
    /// known only once the server has counted, and headers placed then would move what's on
    /// screen.
    @ViewBuilder private func grid(_ items: PagedItems, count: Int, columns columnCount: Int) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.gridSpacing) {
            // The head goes with the list's first rows.
            if focusWindow.start == 0 { head }
            // The rows around focus; see `FocusWindow`.
            LazyVGrid(columns: columns(columnCount), spacing: Metrics.gridSpacing) {
                ForEach(focusWindow.range(count: count, columns: columnCount), id: \.self) { cell(items, $0) }
            }
            .scrollTargetLayout()
        }
        #else
        LazyVGrid(columns: columns(columnCount), alignment: .leading, spacing: Metrics.gridSpacing) {
            ForEach(0..<count, id: \.self) { cell(items, $0) }
        }
        .scrollTargetLayout()
        #endif
    }

    /// The shapes of a screenful of cards, before the list says how long it is.
    private func placeholders(columns columnCount: Int) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gridSpacing) {
            #if os(tvOS)
            head
            #endif
            LazyVGrid(columns: columns(columnCount), alignment: .leading, spacing: Metrics.gridSpacing) {
                ForEach(0..<columnCount * 6, id: \.self) { _ in CardPlaceholder(style: list.style) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
        }
    }

    #if os(tvOS)
    /// Above the grid on Apple TV, where the bar stays over what scrolls under it: the title of a
    /// list opened from another screen, and Sort and Filter. It's a focus section as wide as the
    /// grid, so moving up from any card of the first row reaches Sort and Filter at its end.
    @ViewBuilder private var head: some View {
        if isPresented || query != nil {
            HStack {
                if isPresented {
                    Text(title).font(.title2.bold())
                }
                Spacer()
                if query != nil { sortAndFilter.buttonStyle(.platformGlass) }
            }
            .frame(maxWidth: .infinity)
            .focusSection()
        }
    }
    #endif

    /// Scrolls to a letter's first title.
    private func jump(to letter: String, in items: PagedItems) {
        jumping?.cancel()
        jumping = Task {
            guard let first = await items.start(of: letter), !Task.isCancelled else { return }
            #if os(tvOS)
            if let columnCount, let count = items.count {
                focusWindow.center(on: first, count: count, columns: columnCount)
            }
            #endif
            position.scrollTo(id: first, anchor: .top)
            #if os(tvOS)
            // Focus follows to the letter's first title, once it's loaded and made.
            pendingFocus = first
            focusedIndex = first
            #endif
        }
    }

    private func cell(_ items: PagedItems, _ index: Int) -> some View {
        #if os(tvOS)
        GridCell(items: items, index: index, style: list.style, focus: $focusedIndex, pendingFocus: $pendingFocus)
        #else
        GridCell(items: items, index: index, style: list.style, focus: $focusedIndex)
        #endif
    }

    /// Sort and Filter, filled while a filter narrows the list. Each group has its heading, which
    /// a picker shown inline in a menu leaves out, so the sorts and filters are checkmarked
    /// toggles under one; genres and libraries are submenus named for the one chosen.
    private var sortAndFilter: some View {
        Menu {
            Section("Sort By") {
                ForEach(Sort.allCases) { sort in
                    Toggle(sort.label, isOn: choosing(Optional(sort), in: sortSelection))
                }
            }
            if base?.isPlayed == nil, base?.isFavorite == nil {
                Section("Show") {
                    ForEach(Filter.allCases) { filter in
                        Toggle(filter.label, isOn: choosing(filter, in: filterSelection))
                    }
                }
            }
            if !genres.isEmpty {
                Section("Genre") {
                    Picker(selection: genreSelection) {
                        Text("All Genres").tag(String?.none)
                        ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
                    } label: {
                        Text(query?.genres.first ?? "All Genres")
                    }
                    .pickerStyle(.menu)
                }
            }
            if libraries.count > 1 {
                Section("Library") {
                    Picker(selection: librarySelection) {
                        Text("All Libraries").tag(String?.none)
                        ForEach(libraries) { Text($0.name).tag(Optional($0.id)) }
                    } label: {
                        Text(libraries.first { $0.id == query?.parentId }?.name ?? "All Libraries")
                    }
                    .pickerStyle(.menu)
                }
            }
            if let filterProblem {
                Section("Genres and libraries couldn't load: \(filterProblem)") {
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await loadFilters() } }
                }
            }
        } label: {
            Label("Sort and Filter", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        // Apple TV's menu button reads out nothing of its label by itself. What it's filtered to
        // is in the label too: a toolbar button reads out no value.
        .accessibilityLabel(isFiltered ? "Sort and Filter, filtered to \(filterSummary)" : "Sort and Filter")
        .accessibilityIdentifier("library.sortFilter")
    }

    /// Whether the menu narrows the list to some of its titles, beyond what the list itself does.
    private var isFiltered: Bool {
        guard let query, let base else { return false }
        return query.isPlayed != base.isPlayed || query.isFavorite != base.isFavorite || query.genres != base.genres
            || query.parentId != base.parentId
    }

    /// The filters the menu has set, as they read in a sentence: "Favorites and Drama".
    private var filterSummary: String {
        guard let query, let base else { return "" }
        var parts: [String] = []
        if query.isPlayed != base.isPlayed || query.isFavorite != base.isFavorite { parts.append(Filter(query).label) }
        if query.genres != base.genres { parts += query.genres }
        if query.parentId != base.parentId, let library = libraries.first(where: { $0.id == query.parentId }) {
            parts.append(library.name)
        }
        return parts.formatted(.list(type: .and))
    }

    /// Takes away the menu's filters, leaving its sort.
    private func clearFilters() {
        guard var cleared = query, let base else { return }
        cleared.isPlayed = base.isPlayed
        cleared.isFavorite = base.isFavorite
        cleared.genres = base.genres
        cleared.parentId = base.parentId
        query = cleared
    }

    /// The list's title, or once the menu has put a list picked by its order in another, what
    /// the list holds then (see `title(of:sortedBy:)`).
    private var title: String { Self.title(of: list, sortedBy: query?.sortBy) }

    /// What to call `list` sorted by `sort`. A list picked out by its order, such as Top Rated
    /// Movies or Recently Added Shows, is every title of its kind, which another order shows
    /// for what it is: "Movies", "Shows", "Unwatched Drama Movies". One sorted by name, or that
    /// a person, a collection or a search picks out, keeps its title.
    nonisolated static func title(of list: BrowseList, sortedBy sort: String?) -> String {
        guard case .items(let base) = list.source, let sort, sort != base.sortBy, base.sortBy != "SortName",
              base.searchTerm == nil, base.personIds.isEmpty, base.parentId == nil, base.ids.isEmpty else { return list.title }
        let kinds = base.types.map { type in
            switch type {
            case "Movie": "Movies"
            case "Series": "Shows"
            case "Episode": "Episodes"
            case "BoxSet": "Collections"
            default: type
            }
        }
        var words: [String] = []
        if base.isFavorite == true { words.append("Favorite") }
        if let played = base.isPlayed { words.append(played ? "Watched" : "Unwatched") }
        if !base.genres.isEmpty { words.append(base.genres.formatted(.list(type: .or))) }
        words.append(kinds.formatted(.list(type: .and)))
        return words.joined(separator: " ")
    }

    /// On while `selection` is `value`; turned on, it chooses it.
    private func choosing<Value: Equatable>(_ value: Value, in selection: Binding<Value>) -> Binding<Bool> {
        Binding { selection.wrappedValue == value } set: { if $0 { selection.wrappedValue = value } }
    }

    private var sortSelection: Binding<Sort?> {
        Binding {
            query.flatMap(Sort.init)
        } set: { sort in
            guard let sort, var changed = query else { return }
            sort.apply(to: &changed)
            query = changed
        }
    }

    private var filterSelection: Binding<Filter> {
        Binding {
            query.map(Filter.init) ?? .all
        } set: { filter in
            guard var changed = query else { return }
            filter.apply(to: &changed)
            query = changed
        }
    }

    private var genreSelection: Binding<String?> {
        Binding {
            query?.genres.first
        } set: { genre in
            query?.genres = genre.map { [$0] } ?? []
        }
    }

    private var librarySelection: Binding<String?> {
        Binding {
            query?.parentId
        } set: { library in
            query?.parentId = library
        }
    }

    // MARK: Loading

    /// Starting over shows the new list from its first page; a refresh keeps the list on screen
    /// until the new one is in, with the titles around where it's scrolled, so it goes on screen
    /// in its place. Keeping the index, the refresh doesn't count the letters again while the
    /// list is as long as it was.
    private func load(startingOver: Bool, keepingIndex: Bool = false) async {
        guard let session else { return }
        let next = PagedItems(source: source, client: session.client, userId: session.userId)
        let previous = items
        if startingOver {
            items?.cancel()
            items = next
            refreshProblem = nil
            position = ScrollPosition(idType: Int.self)
            #if os(tvOS)
            focusWindow = FocusWindow()
            #endif
            await next.load()
        } else {
            await next.load(around: previous?.lastShown ?? 0, replacing: keepingIndex ? previous : nil)
        }
        guard !Task.isCancelled else {
            next.cancel()
            return
        }
        if !startingOver {
            if next.count == nil, items?.count != nil {
                refreshProblem = next.problem
            } else {
                items?.cancel()
                items = next
                refreshProblem = nil
            }
        }
    }

    /// The genres and libraries the menu narrows the list to, where the list doesn't fix them.
    private func loadFilters() async {
        guard let session, let base else { return }
        do {
            if base.genres.isEmpty {
                genres = try await session.client.genres(userId: session.userId, types: base.types).map(\.name)
            }
            if base.parentId == nil {
                let kinds = Set(base.types.compactMap(Self.collectionType))
                libraries = try await session.client.libraries(userId: session.userId).filter { kinds.contains($0.collectionType ?? "") }
            }
            filterProblem = nil
        } catch {
            if !error.isCancellation { filterProblem = error.localizedDescription }
        }
    }

    /// The kind of library an item type lives in.
    private static func collectionType(of type: String) -> String? {
        switch type {
        case "Movie": "movies"
        case "Series", "Episode": "tvshows"
        default: nil
        }
    }
}

/// One position in the grid: its card once its page is in, a placeholder of the same size until then.
private struct GridCell: View {
    let items: PagedItems
    let index: Int
    let style: BrowseList.Style
    let focus: FocusState<Int?>.Binding
    #if os(tvOS)
    @Binding var pendingFocus: Int?
    #endif

    var body: some View {
        let item = items.item(at: index)
        NavigationLink(value: item) {
            if let item {
                switch style {
                case .poster: PosterCard(item: item)
                case .landscape: LandscapeCard(item: item)
                }
            } else {
                CardPlaceholder(style: style)
            }
        }
        .buttonStyle(.artwork)
        .focused(focus, equals: index)
        .titleMenu(item) { items.replace($0) }
        .onAppear { items.show(index) }
        #if os(tvOS)
        .onChange(of: item?.id, initial: true) {
            // An index jump's target takes focus once it can: loaded, and so enabled.
            guard item != nil, pendingFocus == index else { return }
            pendingFocus = nil
            focus.wrappedValue = index
        }
        #endif
    }
}
