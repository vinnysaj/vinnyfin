#if os(macOS)
import SwiftUI

/// Portable TV's library, laid out for 1920 points across and scaled to the screen: the tabs
/// along the top, the focused title told about above rows of artwork, and titles' pages. Focus is
/// the browser's; these draw it.
struct TVLibraryView: View {
    let browser: TVBrowser
    @Environment(\.session) private var session

    var body: some View {
        ZStack {
            if session == nil {
                TVMessage(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign In on This Mac",
                          detail: "Sign in to your server in vinnyfin on this Mac to see your library here. YouTube works without it.")
            } else if let page = browser.pages.last {
                TVPageView(page: page)
                    .id(page.id)
                    .transition(.opacity)
            } else {
                switch browser.tab {
                case .home: TVHomeView(browser: browser)
                case .search: TVSearchView(browser: browser)
                }
                TVTabBar(browser: browser)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: browser.pages.map(\.id))
    }
}

// MARK: - Tabs

private struct TVTabBar: View {
    let browser: TVBrowser
    @Environment(\.tvScale) private var scale

    var body: some View {
        HStack(spacing: 12 * scale) {
            ForEach(TVBrowser.Tab.allCases) { tab in
                let isSelected = tab == browser.tab
                let isFocused = isSelected && browser.focusesTabs
                Text(tab.rawValue)
                    .font(.system(size: 30 * scale, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white.opacity(isSelected ? 1 : 0.6))
                    .padding(.horizontal, 30 * scale)
                    .padding(.vertical, 12 * scale)
                    .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(isSelected ? 0.18 : 0)), in: .capsule)
                    .scaleEffect(isFocused ? 1.06 : 1)
                    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(8 * scale)
        .background(.black.opacity(0.35), in: .capsule)
        .padding(.top, 40 * scale)
        .animation(.snappy(duration: 0.2), value: browser.focusesTabs)
        .animation(.snappy(duration: 0.2), value: browser.tab)
    }
}

// MARK: - Home

private struct TVHomeView: View {
    let browser: TVBrowser
    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.tvScale) private var scale

    private var feed: HomeFeed { browser.feed }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVBackdrop(item: browser.homeFocusedItem ?? feed.featured.first)
            VStack(alignment: .leading, spacing: 0) {
                TVHeroInfo(item: browser.homeFocusedItem ?? feed.featured.first)
                    .frame(height: 470 * scale, alignment: .bottomLeading)
                    .padding(.top, 130 * scale)
                rows
            }
            if feed.sessionEnded {
                TVMessage(symbol: "person.crop.circle.badge.exclamationmark", title: "Signed Out",
                          detail: "The server signed vinnyfin out. Sign in again in vinnyfin on this Mac.")
            } else if let error = feed.loadError, feed.rows.isEmpty {
                TVMessage(symbol: "wifi.exclamationmark", title: "Can't Reach the Server", detail: error)
            } else if feed.hasNoTitles {
                TVMessage(symbol: "film.stack", title: "Nothing to Watch Yet", detail: "Your server has no movies or shows for you.")
            } else if feed.rows.isEmpty {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session?.account.userId) {
            guard let session else { return }
            await feed.load(session: session)
        }
        .task(id: browser.homeFocusedItem?.id) {
            guard let session, let item = browser.homeFocusedItem else { return }
            await browser.loadDetail(of: item, session: session)
        }
        // What was watched moved Continue Watching and Next Up.
        .onChange(of: player.endedPlayback) {
            guard let session else { return }
            browser.forgetDetails()
            Task { await feed.load(session: session) }
        }
    }

    private var rows: some View {
        let rows = browser.homeRows
        let focused = browser.focusesTabs ? nil : browser.homeFocus.focused(in: rows)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 34 * scale) {
                    ForEach(feed.rows) { row in
                        let items = feed.items[row.id]
                        if items?.isEmpty != true {
                            TVShelf(title: row.list.title, items: items, style: row.list.style,
                                    focusedColumn: focused?.row.id == row.id ? focused?.column : nil)
                                .id(row.id)
                                .onAppear { feed.rowAppeared(row.id) }
                                .onDisappear { feed.rowDisappeared(row.id) }
                        }
                    }
                }
                .padding(.bottom, 400 * scale)
            }
            .scrollIndicators(.hidden)
            .onChange(of: focused?.row.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }
}

// MARK: - Search

private struct TVSearchView: View {
    let browser: TVBrowser
    @Environment(\.tvScale) private var scale

    private var search: TVSearch { browser.search }

    var body: some View {
        let rows = search.rows
        let focused = browser.focusesTabs ? nil : search.focus.focused(in: rows)
        VStack(alignment: .leading, spacing: 40 * scale) {
            field
                .padding(.top, 150 * scale)
                .padding(.horizontal, 90 * scale)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 34 * scale) {
                        ForEach(search.sections) { section in
                            TVShelf(title: section.title, items: section.items, style: section.style,
                                    focusedColumn: focused?.row.id == section.id ? focused?.column : nil)
                                .id(section.id)
                        }
                    }
                    .padding(.bottom, 400 * scale)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focused?.row.id) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .overlay {
                if let problem = search.problem {
                    TVMessage(symbol: "exclamationmark.magnifyingglass", title: "Search Failed", detail: problem)
                } else if search.isSearching, search.sections.isEmpty {
                    ProgressView().controlSize(.large)
                } else if !search.text.isEmpty, search.sections.isEmpty, !search.isSearching {
                    TVMessage(symbol: "magnifyingglass", title: "No Results", detail: "Nothing on your server is called “\(search.text)”.")
                }
            }
        }
    }

    private var field: some View {
        HStack(spacing: 18 * scale) {
            Image(systemName: "magnifyingglass")
            if search.text.isEmpty {
                Text("Type on your iPhone's remote, or on this Mac's keyboard")
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Text(search.text)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 36 * scale, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 30 * scale)
        .padding(.vertical, 22 * scale)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 20 * scale))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search")
        .accessibilityValue(search.text)
    }
}

// MARK: - A title's page

private struct TVPageView: View {
    let page: TVPage
    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.tvScale) private var scale

    var body: some View {
        let rows = page.rows
        let focused = page.focus.focused(in: rows)
        ZStack(alignment: .topLeading) {
            TVBackdrop(item: page.title)
            VStack(alignment: .leading, spacing: 0) {
                TVHeroInfo(item: page.shown, showsTitle: page.shown.id == page.title.id)
                    .frame(height: 470 * scale, alignment: .bottomLeading)
                    .padding(.top, 80 * scale)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 34 * scale) {
                            actions.id(TVPage.actionsRow)
                            if !page.seasons.isEmpty { seasons.id(TVPage.seasonsRow) }
                            if page.isShow {
                                TVShelf(title: "Episodes", items: page.seasonId == nil ? [] : page.episodes.isEmpty ? nil : page.episodes,
                                        style: .landscape, focusedColumn: focused?.row.id == TVPage.episodesRow ? focused?.column : nil)
                                    .id(TVPage.episodesRow)
                            }
                            if !page.similar.isEmpty {
                                TVShelf(title: "More Like This", items: page.similar, style: .poster,
                                        focusedColumn: focused?.row.id == TVPage.similarRow ? focused?.column : nil)
                                    .id(TVPage.similarRow)
                            }
                        }
                        .padding(.bottom, 400 * scale)
                    }
                    .scrollIndicators(.hidden)
                        .onChange(of: focused?.row.id) { _, id in
                        guard let id else { return }
                        withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
            if let problem = page.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 24 * scale))
                    .foregroundStyle(.orange)
                    .padding(40 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .task {
            guard let session else { return }
            await page.load(session: session)
        }
        .task(id: page.seasonId) {
            guard let session else { return }
            await page.loadEpisodes(session: session)
        }
        .onChange(of: player.endedPlayback) {
            guard let session else { return }
            Task { await page.reload(session: session) }
        }
    }

    private var actions: some View {
        HStack(spacing: 24 * scale) {
            ForEach(Array(page.actions.enumerated()), id: \.element) { column, action in
                TVPill(title: label(for: action), symbol: action == .play ? "play.fill" : "arrow.counterclockwise",
                       isFocused: page.isFocused(TVPage.actionsRow, column))
            }
            if page.actions.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
        .padding(.horizontal, 90 * scale)
        .padding(.vertical, 12 * scale)
    }

    private var seasons: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 16 * scale) {
                    ForEach(Array(page.seasons.enumerated()), id: \.element.id) { column, season in
                        TVPill(title: season.name, isFocused: page.isFocused(TVPage.seasonsRow, column),
                               isSelected: season.id == page.seasonId)
                            .id(season.id)
                    }
                }
                .padding(.horizontal, 90 * scale)
                .padding(.vertical, 12 * scale)
            }
            .scrollIndicators(.hidden)
            .onChange(of: page.seasonId) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id) }
            }
        }
    }

    private func label(for action: TVPage.Action) -> String {
        guard let next = page.next else { return "Play" }
        switch action {
        case .restart:
            return "From Beginning"
        case .play:
            let verb = next.resumeSeconds != nil ? "Resume" : "Play"
            guard next.isEpisode, let code = next.episodeCode else { return verb }
            return "\(verb) \(code)"
        }
    }
}

// MARK: - Pieces

/// A row of artwork: its title, and the cards, scrolled to keep the focused one on screen.
/// Nil items is a row still loading.
private struct TVShelf: View {
    let title: String
    let items: [JellyfinItem]?
    let style: BrowseList.Style
    let focusedColumn: Int?
    @Environment(\.tvScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            Text(title)
                .font(.system(size: 30 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(focusedColumn == nil ? 0.7 : 1))
                .padding(.horizontal, 90 * scale)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 36 * scale) {
                        if let items {
                            ForEach(Array(items.enumerated()), id: \.offset) { column, item in
                                TVCard(item: item, style: style, isFocused: column == focusedColumn)
                                    .id(column)
                            }
                        } else {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 14 * scale)
                                    .fill(.white.opacity(0.08))
                                    .frame(width: cardWidth, height: cardWidth / aspectRatio)
                            }
                        }
                    }
                    .padding(.horizontal, 90 * scale)
                    .padding(.vertical, 22 * scale)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .onChange(of: focusedColumn) { _, column in
                    guard let column else { return }
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(column) }
                }
            }
        }
    }

    private var cardWidth: CGFloat { (style == .landscape ? 400 : 220) * scale }
    private var aspectRatio: CGFloat { style == .landscape ? 16.0 / 9.0 : 2.0 / 3.0 }
}

private struct TVCard: View {
    let item: JellyfinItem
    let style: BrowseList.Style
    let isFocused: Bool
    @Environment(\.session) private var session
    @Environment(\.tvScale) private var scale

    var body: some View {
        let isLandscape = style == .landscape
        VStack(alignment: .leading, spacing: 14 * scale) {
            Artwork(url: isLandscape ? session?.landscape(item, width: 800) : session?.poster(item, width: 500),
                    aspectRatio: isLandscape ? 16.0 / 9.0 : 2.0 / 3.0, cornerRadius: 14 * scale,
                    placeholder: item.isSeries ? "tv" : "film")
                .overlay(alignment: .topTrailing) { WatchBadge(item: item).padding(10 * scale) }
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressBar(fraction: progress)
                            .frame(height: 6 * scale)
                            .padding(12 * scale)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14 * scale)
                        .strokeBorder(.white, lineWidth: isFocused ? 4 * scale : 0)
                }
                .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: 24 * scale, y: 14 * scale)
                .scaleEffect(isFocused ? 1.1 : 1)
            Text(caption)
                .font(.system(size: 22 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(isFocused ? 1 : 0.6))
                .lineLimit(1)
                .padding(.top, isFocused ? 8 * scale : 0)
        }
        .frame(width: (isLandscape ? 400 : 220) * scale)
        .zIndex(isFocused ? 1 : 0)
        .animation(.snappy(duration: 0.2), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(caption)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var caption: String {
        if item.isEpisode {
            return [item.episodeCode, item.name].compactMap(\.self).joined(separator: " · ")
        }
        return item.name
    }
}

/// A button-like pill: Play, a season. White with dark text when focused.
private struct TVPill: View {
    let title: String
    var symbol: String?
    let isFocused: Bool
    var isSelected = false
    @Environment(\.tvScale) private var scale

    var body: some View {
        HStack(spacing: 12 * scale) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.system(size: 28 * scale, weight: .semibold))
        .foregroundStyle(isFocused ? .black : .white)
        .padding(.horizontal, 34 * scale)
        .padding(.vertical, 16 * scale)
        .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(isSelected ? 0.3 : 0.14)), in: .capsule)
        .scaleEffect(isFocused ? 1.08 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 16 * scale, y: 8 * scale)
        .animation(.snappy(duration: 0.2), value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isFocused || isSelected ? .isSelected : [])
    }
}

/// The focused title's backdrop, filling the screen behind everything and fading to black
/// toward the bottom and the left, where the text is.
private struct TVBackdrop: View {
    let item: JellyfinItem?
    @Environment(\.session) private var session

    var body: some View {
        ZStack {
            if let item, let url = session?.backdrop(item) {
                Artwork(url: url, aspectRatio: nil, cornerRadius: 0)
                    .id(url)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.6), .black], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.4), value: item?.id)
        .accessibilityHidden(true)
    }
}

/// What the top of a screen tells about a title: its logo or name, the facts about it, and its
/// overview.
private struct TVHeroInfo: View {
    let item: JellyfinItem?
    /// An episode shows its show's logo above its own name, so the name is told anyway.
    var showsTitle = true
    @Environment(\.session) private var session
    @Environment(\.tvScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            if let item {
                if let logo = session?.logo(item) {
                    Artwork(url: logo, aspectRatio: nil, cornerRadius: 0, contentMode: .fit, label: item.titleName)
                        .frame(width: 560 * scale, height: 170 * scale, alignment: .bottomLeading)
                } else {
                    Text(item.titleName)
                        .font(.system(size: 64 * scale, weight: .bold))
                        .lineLimit(2)
                }
                if item.isEpisode {
                    Text(item.name)
                        .font(.system(size: 34 * scale, weight: .semibold))
                        .lineLimit(1)
                }
                Text(Self.facts(of: item))
                    .font(.system(size: 24 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: 24 * scale))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                        .frame(maxWidth: 1000 * scale, alignment: .leading)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 90 * scale)
        .animation(.easeInOut(duration: 0.2), value: item?.id)
        .accessibilityElement(children: .combine)
    }

    /// "S2 E3 · 2021 · TV-14 · 48 min · Drama, Mystery"
    static func facts(of item: JellyfinItem) -> String {
        var parts = [item.isEpisode ? item.episodeCode : nil, item.premiereYearText, item.officialRating]
        if !item.isSeries { parts.append(item.runtimeText) }
        if let genres = item.genres?.prefix(2), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}

/// A word in the middle of the screen, for what's gone wrong or what's missing.
struct TVMessage: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.tvScale) private var scale

    var body: some View {
        VStack(spacing: 20 * scale) {
            Image(systemName: symbol).font(.system(size: 80 * scale))
            Text(title).font(.system(size: 44 * scale, weight: .bold))
            Text(detail)
                .font(.system(size: 28 * scale))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100 * scale)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.6))
        .accessibilityElement(children: .combine)
    }
}
#endif
