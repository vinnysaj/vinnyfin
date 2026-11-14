#if os(macOS)
import Foundation
import Observation
import OSLog

/// Portable TV's library: Home and Search along the top, and the pages of titles opened from
/// them, moved through with a remote's presses rather than a pointer. Focus lives here rather
/// than in the views, so presses that arrive faster than the screen redraws each count.
@Observable
final class TVBrowser {
    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home", search = "Search"

        var id: Self { self }
    }

    private(set) var tab = Tab.home
    /// Focus is on the tabs along the top, rather than on what's below them.
    private(set) var focusesTabs = false
    /// The titles' pages opened, the last on screen. The tabs show while there are none.
    private(set) var pages: [TVPage] = []
    let feed = HomeFeed()
    let search = TVSearch()
    private(set) var homeFocus = TVFocus()

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let play: (PlaybackRequest) -> Void

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "portable-tv")

    init(accounts: AccountStore, play: @escaping (PlaybackRequest) -> Void) {
        self.accounts = accounts
        self.play = play
    }

    /// Home's rows, for focus to move along; those not loaded yet have nothing in them.
    var homeRows: [TVRow] {
        feed.rows.map { TVRow(id: $0.id, count: feed.items[$0.id]?.count ?? 0) }
    }

    /// The title focused on Home, which the top of the screen tells about: in full once loaded,
    /// as most rows come without overviews.
    var homeFocusedItem: JellyfinItem? {
        guard let (row, column) = homeFocus.focused(in: homeRows), let item = feed.items[row.id]?[column] else { return nil }
        return details[item.id] ?? item
    }

    /// Titles in full, by id, as focus has rested on them.
    private(set) var details: [String: JellyfinItem] = [:]

    /// Loads the focused title in full, once focus has rested on it a moment.
    func loadDetail(of item: JellyfinItem, session: ServerSession) async {
        guard details[item.id] == nil, item.overview == nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            details[item.id] = try await session.client.item(id: item.id, userId: session.userId)
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("Couldn't load \(item.id, privacy: .public) in full: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Presses

    func press(_ press: TVPress) {
        if let page = pages.last {
            pressOnPage(page, press)
        } else if focusesTabs {
            pressOnTabs(press)
        } else {
            pressOnTab(press)
        }
    }

    /// Lets go of the titles loaded in full, whose watch state a playback may have changed.
    func forgetDetails() {
        details = [:]
    }

    /// Back to Home's first row, as the remote's TV button goes.
    func goHome() {
        pages = []
        tab = .home
        focusesTabs = false
        homeFocus = TVFocus()
    }

    /// Shows Search with `text` in its field, as typed on the remote.
    func searchFor(_ text: String) {
        pages = []
        tab = .search
        focusesTabs = false
        search.set(text, session: accounts.session)
    }

    /// Types on the Mac's keyboard into Search, which comes up for it.
    func type(_ characters: String) {
        searchFor(tab == .search && pages.isEmpty ? search.text + characters : characters)
    }

    func deleteBackward() {
        guard tab == .search, pages.isEmpty, !search.text.isEmpty else { return }
        search.set(String(search.text.dropLast()), session: accounts.session)
    }

    private func pressOnTabs(_ press: TVPress) {
        let tabs = Tab.allCases
        let index = tabs.firstIndex(of: tab) ?? 0
        switch press {
        case .left where index > 0: tab = tabs[index - 1]
        case .right where index < tabs.count - 1: tab = tabs[index + 1]
        // Into the tab, unless it has nothing to focus.
        case .down, .select: focusesTabs = !hasContent
        default: break
        }
    }

    private var hasContent: Bool {
        switch tab {
        case .home: homeFocus.focused(in: homeRows) != nil
        case .search: search.focus.focused(in: search.rows) != nil
        }
    }

    private func pressOnTab(_ press: TVPress) {
        switch press {
        case .up, .down, .left, .right:
            let direction = TVDirection(press)
            let moved = switch tab {
            case .home: homeFocus.move(direction, in: homeRows)
            case .search: search.focus.move(direction, in: search.rows)
            }
            // Up past the top row, or with nothing to focus, goes to the tabs.
            if !moved, direction == .up || !hasContent { focusesTabs = true }
        case .select:
            let item = switch tab {
            case .home: homeFocusedItem
            case .search: search.focusedItem
            }
            if let item { open(item) } else { focusesTabs = true }
        case .back:
            focusesTabs = true
        case .home, .text, .point, .click, .scroll, .fullScreen, .volumeUp, .volumeDown, .mute, .sleep:
            break
        }
    }

    private func pressOnPage(_ page: TVPage, _ press: TVPress) {
        switch press {
        case .up, .down, .left, .right:
            _ = page.move(TVDirection(press))
        case .select:
            switch page.select() {
            case .play(let request): play(request)
            case .open(let item): open(item)
            case nil: break
            }
        case .back:
            pages.removeLast()
        case .home, .text, .point, .click, .scroll, .fullScreen, .volumeUp, .volumeDown, .mute, .sleep:
            break
        }
    }

    /// Opens a title's page: a movie's, or a show's, for an episode too.
    private func open(_ item: JellyfinItem) {
        pages.append(TVPage(picked: item))
    }
}

private extension TVDirection {
    /// The direction of a move press; anything else is taken as down.
    init(_ press: TVPress) {
        switch press {
        case .up: self = .up
        case .left: self = .left
        case .right: self = .right
        default: self = .down
        }
    }
}

// MARK: - Search

/// Portable TV's Search: the text typed on the remote or the Mac's keyboard, and the movies,
/// shows and episodes with it in their names.
@Observable
final class TVSearch {
    struct Section: Identifiable {
        let id: String
        let title: String
        let items: [JellyfinItem]
        let style: BrowseList.Style
    }

    private(set) var text = ""
    private(set) var sections: [Section] = []
    private(set) var isSearching = false
    private(set) var problem: String?
    var focus = TVFocus()

    @ObservationIgnored private var task: Task<Void, Never>?

    var rows: [TVRow] { sections.map { TVRow(id: $0.id, count: $0.items.count) } }

    var focusedItem: JellyfinItem? {
        guard let (row, column) = focus.focused(in: rows) else { return nil }
        return sections.first { $0.id == row.id }?.items[column]
    }

    func set(_ text: String, session: ServerSession?) {
        guard text != self.text else { return }
        self.text = text
        task?.cancel()
        task = Task { await search(session: session) }
    }

    private func search(session: ServerSession?) async {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard let session, !term.isEmpty else {
            sections = []
            problem = nil
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
        func query(_ types: [String]) -> JellyfinClient.ItemQuery {
            var query = JellyfinClient.ItemQuery(types: types)
            query.searchTerm = term
            query.fields = JellyfinClient.listFields
            query.limit = 24
            return query
        }
        do {
            async let movies = session.client.items(userId: session.userId, query(["Movie"]))
            async let shows = session.client.items(userId: session.userId, query(["Series"]))
            async let episodes = session.client.items(userId: session.userId, query(["Episode"]))
            let found = try await [
                Section(id: "movies", title: "Movies", items: movies.items, style: .poster),
                Section(id: "shows", title: "Shows", items: shows.items, style: .poster),
                Section(id: "episodes", title: "Episodes", items: episodes.items, style: .landscape),
            ]
            guard !Task.isCancelled else { return }
            sections = found.filter { !$0.items.isEmpty }
            focus = TVFocus()
            problem = nil
        } catch {
            guard !error.isCancellation else { return }
            problem = error.localizedDescription
        }
    }
}

// MARK: - A title's page

/// A movie's or a show's page on Portable TV: what Play plays, a show's seasons and their
/// episodes, and titles like it.
@Observable
final class TVPage: Identifiable {
    enum Action: String, Identifiable {
        case play, restart

        var id: Self { self }
    }

    /// What a press of Select on the page does.
    enum Selection {
        case play(PlaybackRequest)
        case open(JellyfinItem)
    }

    static let actionsRow = "actions"
    static let seasonsRow = "seasons"
    static let episodesRow = "episodes"
    static let similarRow = "similar"

    let id = UUID()
    /// What was picked to open the page: a movie, a show, or an episode, whose show it is.
    let picked: JellyfinItem
    /// The movie or the show, in full once loaded.
    private(set) var title: JellyfinItem
    private(set) var seasons: [JellyfinItem] = []
    /// The season whose episodes show; focus moving along the seasons picks it.
    private(set) var seasonId: String?
    private(set) var episodes: [JellyfinItem] = []
    /// What Play plays: the movie, the episode picked, or what's next in the show.
    private(set) var next: JellyfinItem?
    private(set) var similar: [JellyfinItem] = []
    private(set) var problem: String?
    private(set) var focus = TVFocus()

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "portable-tv")

    init(picked: JellyfinItem) {
        self.picked = picked
        title = picked
        if picked.isEpisode {
            next = picked
            seasonId = picked.seasonId
        } else if !picked.isSeries {
            next = picked
        }
        focus.focus(row: Self.actionsRow)
    }

    var isShow: Bool { picked.isSeries || picked.isEpisode }

    var actions: [Action] {
        guard let next else { return [] }
        return next.resumeSeconds != nil ? [.play, .restart] : [.play]
    }

    var rows: [TVRow] {
        [
            TVRow(id: Self.actionsRow, count: actions.count),
            TVRow(id: Self.seasonsRow, count: seasons.count),
            TVRow(id: Self.episodesRow, count: episodes.count),
            TVRow(id: Self.similarRow, count: similar.count),
        ]
    }

    /// What the top of the page tells about: the episode or the title like it that has focus,
    /// else the page's own.
    var shown: JellyfinItem {
        guard let (row, column) = focus.focused(in: rows) else { return title }
        switch row.id {
        case Self.episodesRow: return episodes[column]
        case Self.similarRow: return similar[column]
        default: return title
        }
    }

    func isFocused(_ row: String, _ column: Int) -> Bool {
        focus.isFocused(row: row, column: column, in: rows)
    }

    func move(_ direction: TVDirection) -> Bool {
        let moved = focus.move(direction, in: rows)
        // Moving along the seasons shows each one's episodes, as Apple TV's apps do.
        if moved, let (row, column) = focus.focused(in: rows), row.id == Self.seasonsRow, seasons[column].id != seasonId {
            seasonId = seasons[column].id
            episodes = []
            focus.forget(row: Self.episodesRow)
        }
        return moved
    }

    func select() -> Selection? {
        guard let (row, column) = focus.focused(in: rows) else { return nil }
        switch row.id {
        case Self.actionsRow:
            guard let next else { return nil }
            return .play(.item(next, fromBeginning: actions[column] == .restart))
        case Self.seasonsRow:
            _ = focus.move(.down, in: rows)
            return nil
        case Self.episodesRow:
            return .play(.item(episodes[column]))
        case Self.similarRow:
            return .open(similar[column])
        default:
            return nil
        }
    }

    // MARK: Loading

    func load(session: ServerSession) async {
        let client = session.client
        let userId = session.userId
        let titleId = picked.titleId
        do {
            if isShow {
                async let detail = client.item(id: titleId, userId: userId)
                async let seasons = client.seasons(seriesId: titleId, userId: userId)
                async let nextUp = client.nextUp(userId: userId, seriesId: titleId, limit: 1)
                title = try await detail
                let found = try await seasons
                self.seasons = found
                let upNext = try await nextUp.items.first
                if !picked.isEpisode { next = upNext }
                if seasonId == nil {
                    seasonId = next?.seasonId ?? found.first { ($0.indexNumber ?? 0) > 0 }?.id ?? found.first?.id
                }
                if let index = found.firstIndex(where: { $0.id == seasonId }) { focus.focus(row: Self.seasonsRow, column: index) }
                focus.focus(row: Self.actionsRow)
            } else {
                let detail = try await client.item(id: picked.id, userId: userId)
                title = detail
                next = detail
            }
            problem = nil
        } catch {
            guard !error.isCancellation else { return }
            problem = "Couldn't load \(picked.titleName): \(error.localizedDescription)"
        }
        do {
            similar = try await client.similar(to: titleId, userId: userId)
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("Couldn't load titles like \(titleId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The season's episodes, with focus waiting on the one Play plays when it's among them.
    func loadEpisodes(session: ServerSession) async {
        guard isShow, let seasonId else { return }
        do {
            let found = try await session.client.episodes(seriesId: picked.titleId, seasonId: seasonId, userId: session.userId,
                                                          fields: "Overview,PrimaryImageAspectRatio")
            guard seasonId == self.seasonId else { return }
            episodes = found
            let landing = found.firstIndex { $0.id == next?.id } ?? found.firstIndex { !$0.isPlayed } ?? 0
            let row = focus.row
            focus.focus(row: Self.episodesRow, column: landing)
            if let row { focus.focus(row: row) }
            // A show with nothing next plays its first episode not watched.
            if next == nil { next = found.first { !$0.isPlayed } ?? found.first }
        } catch {
            guard !error.isCancellation else { return }
            problem = "Couldn't load the episodes: \(error.localizedDescription)"
        }
    }

    /// What a playback that ended changed: where the show goes on, and the watch state shown.
    func reload(session: ServerSession) async {
        let client = session.client
        let userId = session.userId
        do {
            if isShow {
                async let detail = client.item(id: picked.titleId, userId: userId)
                async let nextUp = client.nextUp(userId: userId, seriesId: picked.titleId, limit: 1)
                title = try await detail
                if let upNext = try await nextUp.items.first { next = upNext }
                if let seasonId {
                    let found = try await client.episodes(seriesId: picked.titleId, seasonId: seasonId, userId: userId,
                                                          fields: "Overview,PrimaryImageAspectRatio")
                    if seasonId == self.seasonId { episodes = found }
                }
            } else {
                let detail = try await client.item(id: picked.id, userId: userId)
                title = detail
                next = detail
            }
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("Couldn't load the watch state again: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
