import AppIntents
import SwiftUI

/// Where a title in a list leads: a show's page, a collection's titles, or a movie's or episode's page.
struct ItemDestination: View {
    let item: JellyfinItem

    var body: some View {
        page
            // A page of its own for each title. A link puts its title in place of the stack's
            // page at the same depth, which would otherwise keep the last title's state: an
            // episode picked on it, the season shown, the details and the version picked.
            .id(item.id)
    }

    @ViewBuilder private var page: some View {
        if item.isSeries {
            SeriesView(series: item)
        } else if item.isSeason, let seriesId = item.seriesId {
            SeriesView(series: JellyfinItem(id: seriesId, name: item.seriesName ?? item.name, type: "Series"), initialSeasonId: item.id)
        } else if item.isCollection {
            LibraryGridView(list: .collection(item))
        } else {
            ItemDetailView(item: item)
        }
    }
}

extension View {
    /// Where the titles and lists in a navigation stack lead.
    func itemDestinations() -> some View {
        navigationDestination(for: JellyfinItem.self) { ItemDestination(item: $0) }
            .navigationDestination(for: BrowseList.self) { LibraryGridView(list: $0) }
            .navigationDestination(for: Person.self) { PersonView(person: $0).id($0.id) }
    }

    /// Lets the stack's pages open a title as its next page where a link can't be, such as from
    /// a menu's command, by adding it to `path`. Every page is on the path, so a link on any of
    /// them leads on from it.
    func opensTitles(on path: Binding<NavigationPath>) -> some View {
        environment(\.openTitle, OpenTitleAction { path.wrappedValue.append($0) })
    }
}

/// Opens a title as the next page of the navigation stack it's called in (see `opensTitles(on:)`).
struct OpenTitleAction {
    let open: (JellyfinItem) -> Void

    func callAsFunction(_ item: JellyfinItem) {
        open(item)
    }
}

extension EnvironmentValues {
    @Entry var openTitle: OpenTitleAction?
}

/// A movie or an episode: play it, pick a version, download it, and more like it. An episode's
/// page leads to its show and has the show's seasons and episodes, and picking another episode
/// there shows that one in its place. Offline it shows the details and artwork saved with a download.
struct ItemDetailView: View {
    /// The title the page opened on.
    let item: JellyfinItem

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    @Environment(\.scenePhase) private var scenePhase
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    /// Another episode of the show, picked on the page, that it shows in place of `item`.
    @State private var picked: JellyfinItem?
    @State private var detail: JellyfinItem?
    @State private var similar: [JellyfinItem] = []
    /// The title `similar` is like: an episode's show.
    @State private var similarTitleId: String?
    @State private var loadError: LoadFailure?
    /// The server answered that it doesn't have the title, which asking again won't change.
    @State private var isGone = false
    /// A version the user picked, for plays and downloads from this page; nil lets them choose by
    /// quality. It isn't kept: every other playback starts with the version the quality allows.
    @State private var pickedSourceId: String?
    /// On screen, rather than under a page pushed over it or in another tab.
    @State private var isOnScreen = false
    /// How many times the page has reloaded the watch state, which the season row reloads with.
    @State private var reloads = 0
    #if os(tvOS)
    @FocusState private var playFocused: Bool
    /// Bounds the page's default focus, Play, from the season row's.
    @Namespace private var focusScope
    /// Where the page's rows are, for holding the focused one in place.
    @State private var rowLayout = RowPageLayout()
    #else
    /// Back at the top for another episode picked, to show it.
    @State private var scrollPosition = ScrollPosition()
    #endif

    /// The title the page shows.
    private var page: JellyfinItem { picked ?? item }

    /// The server's details, or until they come (offline, never) the ones saved with a download.
    private var loaded: JellyfinItem? {
        #if os(tvOS)
        detail
        #else
        detail ?? downloads.jobs(forItem: page.id).lazy.compactMap(\.item).first
        #endif
    }
    private var shown: JellyfinItem { loaded ?? page }
    private var sources: [MediaSource] { loaded?.mediaSources ?? [] }
    private var playbackSource: MediaSource? {
        sources.first { $0.id == pickedSourceId } ?? VersionChooser.choose(from: sources, limit: settings.streamingLimit)
    }

    /// A finished download of the title, which plays when the server no longer has it.
    private var isDownloaded: Bool {
        #if os(tvOS)
        false
        #else
        downloads.jobs(forItem: page.id).contains { $0.status == .completed }
        #endif
    }

    var body: some View {
        EdgeToEdgeScrollView(underTopBars: true) {
            VStack(alignment: .leading, spacing: 28) {
                DetailHero(item: shown, eyebrow: shown.isEpisode ? shown.seriesName : nil, eyebrowLink: series,
                           badgesSource: playbackSource) {
                    actions
                }
                #if os(tvOS)
                .pageRow("hero", in: rowLayout)
                #endif
                VStack(alignment: .leading, spacing: 28) {
                    if isGone {
                        TitleGoneNotice(playsDownload: isDownloaded)
                            .padding(.horizontal, Metrics.edge)
                    } else if let loadError {
                        LoadFailureNotice(loadError) { Task { await load() } }
                            .padding(.horizontal, Metrics.edge)
                    }
                    if !isGone, shown.isNotYetAvailable() { notYetAvailableNote }
                    OverviewText(item: shown).padding(.horizontal, Metrics.edge)
                    if sources.count > 1 { versions }
                    if page.isEpisode, !isGone {
                        SeasonBrowser(episode: shown, reloads: reloads) { showEpisode($0) } onChange: { apply($0) }
                            #if os(tvOS)
                            // The seasons and the episodes together, so the season stays in view
                            // over the episodes as focus moves along them.
                            .pageRow("episodes", in: rowLayout)
                            #endif
                    }
                    ScenesShelf(item: shown, pickedSourceId: pickedSourceId, streamingSource: playbackSource)
                        #if os(tvOS)
                        .pageRow("scenes", in: rowLayout)
                        #endif
                    if let detail {
                        CastAndCrewShelf(credits: Credits(people: detail.people ?? []))
                            #if os(tvOS)
                            .pageRow("cast", in: rowLayout)
                            #endif
                        TitleExtrasShelf(item: detail)
                            #if os(tvOS)
                            .pageRow("extras", in: rowLayout)
                            #endif
                    }
                    if !similar.isEmpty {
                        MoreLikeThisShelf(title: shown, titles: $similar)
                        #if os(tvOS)
                        .pageRow("similar", in: rowLayout)
                        #endif
                    }
                    if !isGone {
                        TitleInformation(item: shown, source: playbackSource, credits: Credits(people: detail?.people ?? []))
                            #if os(tvOS)
                            .pageRow("information", in: rowLayout)
                            #endif
                    }
                }
                .padding(.bottom, Metrics.edge)
            }
            #if os(tvOS)
            .rowPageContent(rowLayout)
            #endif
        }
        #if os(tvOS)
        .rowPage(rowLayout)
        // Focus starts on Play, also for a page opened from a link at launch; the season row's
        // own default applies only as focus moves into it. Coming back to the page leaves focus
        // where it was.
        .focusScope(focusScope)
        .defaultFocus($playFocused, true)
        // Another episode shown: up to its Play, which scrolls the page back to its top.
        .onChange(of: shown.id) { playFocused = true }
        #else
        .scrollPosition($scrollPosition)
        #endif
        .refreshable { await load(refreshing: true) }
        .pageBackground()
        .screenTitle(shown.name)
        .inlineNavigationTitle()
        .heroScrollEdge()
        .handoffPage(shown)
        // Siri knows which title the page is about: "play this", "download this".
        .appEntityIdentifier(EntityIdentifier.title(page))
        .task(id: page.id) { await load() }
        // A playback that ended moved where the title resumes, or finished it.
        .onChange(of: player.endedPlayback) {
            similar = player.endedPlayback.applied(to: similar)
            // Started here, the playback may have moved on to a later episode, which shows instead.
            if let watched = player.endedPlayback.episodeToShow(onPageOf: page) { return showEpisode(watched) }
            Task { await loadDetail() }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        // Back in the app, what was watched elsewhere in the meantime.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isOnScreen, !isGone else { return }
            reloads += 1
            Task { await loadDetail() }
        }
    }

    /// Play and its kin, then the rest: in one row, or where that doesn't fit, Play's on a row
    /// above the rest's.
    private var actions: some View {
        TitleActionsLayout {
            if !isGone || isDownloaded { playButton }
            Group { secondaryButtons }
                .layoutValue(key: SecondaryTitleAction.self, value: true)
        }
        .focusCaptionRoom()
    }

    @ViewBuilder private var playButton: some View {
        if shown.isNotYetAvailable() {
            notYetAvailableButtons
        } else {
            #if os(tvOS)
            PlayButton(item: shown, mediaSourceId: pickedSourceId, focus: $playFocused)
            #else
            PlayButton(item: shown, mediaSourceId: pickedSourceId)
            #endif
        }
    }

    /// In Play's place for a title with nothing to play yet: that it isn't out, as a status rather
    /// than a button, and Check Again, which has the server look for it once more, as it does each
    /// time the page loads.
    @ViewBuilder private var notYetAvailableButtons: some View {
        Label("Not Yet Available", systemImage: "clock")
            .font(.headline)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityIdentifier("detail.notYetAvailable")
        Button {
            Task { await loadDetail() }
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        #if os(tvOS)
        .focused($playFocused)
        #endif
        .accessibilityIdentifier("detail.checkAgain")
    }

    /// Without the title on the server, only what its download still does.
    @ViewBuilder private var secondaryButtons: some View {
        let available = !shown.isNotYetAvailable()
        #if !os(tvOS)
        if available, !isGone || isDownloaded {
            DownloadButton(item: loaded, source: pickedSourceId.flatMap { id in sources.first { $0.id == id } })
        }
        #endif
        if !isGone {
            WatchedButton(item: shown) { detail = $0 }
            FavoriteButton(item: shown) { detail = $0 }
            if available {
                PlayElsewhereButton(subject: .title(shown, mediaSourceId: pickedSourceId))
                    .help(PlayElsewhereSheet.title)
            }
        }
    }

    /// Why there's no Play, under the buttons: when it comes out, or that nothing's out yet.
    private var notYetAvailableNote: some View {
        let when = NotYetAvailableOverlay.day(of: shown).map { "\(shown.isEpisode ? "Airs" : "Comes out") \($0). " }
            ?? "Nothing of it is out yet. "
        return Text(when + "It plays here as soon as any copy of it is out, even one filmed in a theater.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, Metrics.edge)
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(sources.count) Versions").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                VersionPicker(sources: sources, selection: Binding(get: { playbackSource?.id }, set: { pickedSourceId = $0 }))
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 16))
            Text("Plays and downloads from this page use the version picked here. Everywhere else, and once you leave the page, they start with the one closest to your quality settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metrics.edge)
        .frame(maxWidth: 900, alignment: .leading)
    }

    /// The episode's show, which the name over its title leads to, opened on the episode's season.
    /// From the details: a link names only the episode.
    private var series: JellyfinItem? {
        guard shown.isEpisode, let seriesId = shown.seriesId else { return nil }
        let name = shown.seriesName ?? ""
        guard let seasonId = shown.seasonId else { return JellyfinItem(id: seriesId, name: name, type: "Series") }
        var season = JellyfinItem(id: seasonId, name: name, type: "Season")
        season.seriesId = seriesId
        season.seriesName = name
        return season
    }

    /// Shows another episode of the show in this one's place, from the top of the page, with
    /// Apple TV's focus on Play. The episode shown, picked again, goes back up to its top too.
    private func showEpisode(_ episode: JellyfinItem) {
        guard episode.id != page.id else {
            #if os(tvOS)
            playFocused = true
            #else
            withAnimation { scrollPosition.scrollTo(edge: .top) }
            #endif
            return
        }
        let sameTitle = episode.titleId == page.titleId
        detail = nil
        pickedSourceId = nil
        loadError = nil
        isGone = false
        if !sameTitle { similar = [] }
        picked = episode
        // Apple TV's focus moves to Play as the episode shows, and the page scrolls up after it.
        #if !os(tvOS)
        withAnimation { scrollPosition.scrollTo(edge: .top) }
        #endif
    }

    /// What the season row changed of the episode shown, such as its watched state from a card's
    /// menu, so the hero says the same.
    private func apply(_ updated: JellyfinItem) {
        guard updated.id == shown.id, updated.userData != shown.userData else { return }
        var changed = shown
        changed.userData = updated.userData
        detail = changed
    }

    /// The details and the titles like it. Refreshing asks for both again, and has the season row
    /// reload its episodes.
    private func load(refreshing: Bool = false) async {
        let titleId = page.titleId
        if refreshing { reloads += 1 }
        await loadDetail()
        guard let session, !isGone, refreshing || similar.isEmpty || titleId != similarTitleId else { return }
        do {
            similar = try await session.client.similar(to: titleId, userId: session.userId, limit: MoreLikeThisShelf.length)
            similarTitleId = titleId
        } catch {
            guard !error.isCancellation else { return }
            similar = []
            loadError = loadError ?? LoadFailure("Couldn't Load Titles Like This", error: error)
        }
    }

    private func loadDetail() async {
        guard let session else { return }
        let id = page.id
        // Only this title's details, so a load that fails can't leave another title's actions.
        if detail?.id != id { detail = nil }
        do {
            let found = try await session.client.item(id: id, userId: session.userId)
            guard id == page.id else { return }
            detail = found
            loadError = nil
            isGone = false
        } catch JellyfinError.http(let status, _) where status == 404 {
            guard id == page.id else { return }
            detail = nil
            loadError = nil
            isGone = true
        } catch {
            guard !error.isCancellation, id == page.id else { return }
            loadError = LoadFailure("Couldn't Load the Details", error: error)
        }
    }
}

/// A title page's More Like This: the titles the server ranks as like it, as posters with the
/// title's menu. See All, which lists more of them, is there only when the row may not have them
/// all: the server doesn't say how many there are, so a row with as many as it asked for may not.
struct MoreLikeThisShelf: View {
    /// How many titles the row asks the server for.
    static let length = 16

    /// The title they're like.
    let title: JellyfinItem
    @Binding var titles: [JellyfinItem]

    var body: some View {
        Shelf(title: "More Like This", seeAll: titles.count >= Self.length ? .moreLike(title) : nil, items: titles,
              cardWidth: Metrics.posterWidth) { other in
            NavigationLink(value: other) { PosterCard(item: other) }
                .buttonStyle(.artwork)
                .titleMenu(other) { updated in
                    if let index = titles.firstIndex(where: { $0.id == updated.id }) { titles[index] = updated }
                }
        }
    }
}

/// In place of a title's details when the server no longer has it, with nothing to try again:
/// asking again finds nothing either.
struct TitleGoneNotice: View {
    /// A download of it is on this device, which still plays.
    var playsDownload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No Longer in Your Library", systemImage: "questionmark.folder")
                .font(.headline)
            Text(playsDownload
                 ? "The server doesn't have it anymore. The download on this device still plays."
                 : "The server doesn't have it anymore. It may have been removed or moved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.gone")
    }
}

/// Marks the buttons of a title's action row that come after Play and its kin, which go on a row
/// of their own when not all of them fit on one.
nonisolated struct SecondaryTitleAction: LayoutValueKey {
    static let defaultValue = false
}

/// The buttons over a title's artwork: all in one row when they fit, or else Play's on a row above
/// the rest's (`SecondaryTitleAction`), each going on to more rows as it needs, which at the
/// largest text sizes puts one button on each. A layout rather than a choice of stacks keeps each
/// button the same view however they're laid out, so focus stays on Play as the row rearranges,
/// such as when Start Over joins it.
struct TitleActionsLayout: Layout {
    var spacing: CGFloat = 12

    private struct Placement {
        let index: Int
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width)
        let width = lines.map { line in line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1)) }.max() ?? 0
        let height = lines.reduce(0) { $0 + lineHeight($1) } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            let height = lineHeight(line)
            var x = bounds.minX
            for placement in line {
                subviews[placement.index].place(at: CGPoint(x: x, y: y + (height - placement.size.height) / 2),
                                                proposal: ProposedViewSize(placement.size))
                x += placement.size.width + spacing
            }
            y += height + spacing
        }
    }

    private func lineHeight(_ line: [Placement]) -> CGFloat {
        line.map(\.size.height).max() ?? 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [[Placement]] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = width ?? .infinity
        let oneRow = ideal.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, ideal.count - 1))
        if oneRow <= available { return [ideal.enumerated().map { Placement(index: $0.offset, size: $0.element) }] }
        var lines: [[Placement]] = []
        var line: [Placement] = []
        var lineWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            // Wider than the row, as a long title is at the largest text sizes: as wide as the row, taller.
            let size = ideal[index].width > available ? subview.sizeThatFits(ProposedViewSize(width: available, height: nil)) : ideal[index]
            let startsGroup = subview[SecondaryTitleAction.self] && !(line.last.map { subviews[$0.index][SecondaryTitleAction.self] } ?? true)
            if !line.isEmpty, startsGroup || lineWidth + spacing + size.width > available {
                lines.append(line)
                line = []
                lineWidth = 0
            }
            lineWidth += (line.isEmpty ? 0 : spacing) + size.width
            line.append(Placement(index: index, size: size))
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

/// Play, or Resume with the time left, plus Start Over when there's a position.
struct PlayButton: View {
    let item: JellyfinItem
    var mediaSourceId: String?
    #if os(tvOS)
    /// Play's focus, which the page starts on.
    let focus: FocusState<Bool>.Binding
    #endif
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            player.play(.item(item, mediaSourceId: mediaSourceId, loaded: item))
        } label: {
            Label(label, systemImage: "play.fill")
                .frame(minWidth: 120)
        }
        .buttonStyle(.platformGlassProminent)
        .controlSize(.large)
        // Its title on one line: the row's other buttons would otherwise take width it needs. At
        // the accessibility text sizes, where one line can be wider than the screen, it wraps.
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        .accessibilityLabel(spokenLabel)
        .accessibilityInputLabels([item.resumeSeconds != nil ? "Resume" : "Play", label])
        .accessibilityIdentifier("detail.play")
        #if os(tvOS)
        .focused(focus)
        #endif
        if item.resumeSeconds != nil {
            Button {
                player.play(.item(item, mediaSourceId: mediaSourceId, fromBeginning: true, loaded: item))
            } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.platformGlass)
            .controlSize(.large)
        }
    }

    private var label: String {
        guard item.resumeSeconds != nil else { return "Play" }
        return item.timeLeftText.map { "Resume · \($0)" } ?? "Resume"
    }

    /// "Resume, 1 hour, 20 minutes left", rather than VoiceOver spelling out "hr" and "min".
    private var spokenLabel: String {
        guard item.resumeSeconds != nil else { return "Play" }
        return item.spokenTimeLeft.map { "Resume, \($0)" } ?? "Resume"
    }
}

/// Marks a title watched or unwatched, the whole of a show or season.
struct WatchedButton: View {
    let item: JellyfinItem
    /// Told of the change as it's made, and again of the item as it was if the server refuses it.
    let onChange: (JellyfinItem) -> Void
    /// Called once the server has the change, for what it changed besides the item, such as a
    /// show's episodes.
    var afterChange: () async -> Void = {}
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages
    /// Counts the presses, for the haptic: the state also changes as a playback ends.
    @State private var presses = 0

    var body: some View {
        Button(action: press) {
            Label("Watched", systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .sensoryFeedback(.selection, trigger: presses)
        .focusCaption(item.isPlayed ? "Watched" : "Mark as Watched")
        .help(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")
        // To VoiceOver and Voice Control a switch named Watched, on when watched. The button as
        // drawn would always read as on: SwiftUI takes a checkmark symbol for a selection.
        .accessibilityRepresentation {
            Toggle("Watched", isOn: Binding(get: { item.isPlayed }, set: { _ in press() }))
        }
        .accessibilityIdentifier("detail.watched")
    }

    private func press() {
        presses += 1
        Task { await toggle() }
    }

    private func toggle() async {
        guard let session else { return }
        await WatchActions.setPlayed(!item.isPlayed, on: item, session: session, messages: messages, onChange: onChange)
        await afterChange()
    }
}

/// Adds a title to the favorites or takes it out.
struct FavoriteButton: View {
    let item: JellyfinItem
    let onChange: (JellyfinItem) -> Void
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages
    /// Counts the presses, for the haptic, and the ones that added it, for the heart's bounce.
    @State private var presses = 0
    @State private var additions = 0

    var body: some View {
        Button(action: press) {
            Label("Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: additions)
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .sensoryFeedback(.selection, trigger: presses)
        .focusCaption(item.isFavorite ? "In Favorites" : "Add to Favorites")
        .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        // To VoiceOver and Voice Control a switch named Favorite, on when it's one.
        .accessibilityRepresentation {
            Toggle("Favorite", isOn: Binding(get: { item.isFavorite }, set: { _ in press() }))
        }
        .accessibilityIdentifier("detail.favorite")
    }

    private func press() {
        presses += 1
        if !item.isFavorite { additions += 1 }
        Task { await toggle() }
    }

    private func toggle() async {
        guard let session else { return }
        await WatchActions.setFavorite(!item.isFavorite, on: item, session: session, messages: messages, onChange: onChange)
    }
}

extension View {
    /// What a round icon button does or is, under it on Apple TV while it has focus: there's no
    /// pointer there for the Mac's help tag to show at. Elsewhere, nothing.
    func focusCaption(_ caption: String) -> some View {
        #if os(tvOS)
        modifier(FocusCaption(caption: caption))
        #else
        self
        #endif
    }

    /// Room under a row of buttons for the line `focusCaption` shows under them on Apple TV, so the
    /// caption doesn't run into what's below. Elsewhere, nothing.
    func focusCaptionRoom() -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: FocusCaption.gap) {
            self
            Text(verbatim: " ").font(FocusCaption.font).hidden()
        }
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct FocusCaption: ViewModifier {
    static let font = Font.caption
    /// Between the button and its caption, clear of the button as focus lifts it.
    static let gap: CGFloat = 6

    let caption: String
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            // From the button's leading edge, which keeps the first one's inside the page's margin.
            .overlay(alignment: .bottomLeading) {
                Text(caption)
                    .font(Self.font)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.leading, 8)
                    .alignmentGuide(.bottom) { $0[.top] - Self.gap }
                    .opacity(isFocused ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
                    // The button's name already says it.
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
    }
}
#endif

#if !os(tvOS)
/// Download, then the download's progress, then a way to delete it.
struct DownloadButton: View {
    /// Nil until the item's versions have loaded.
    let item: JellyfinItem?
    /// A version the user picked; otherwise the download quality decides.
    let source: MediaSource?

    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages

    var body: some View {
        let jobs = item.map { downloads.jobs(forItem: $0.id) } ?? []
        let isDownloaded = jobs.contains { $0.status == .completed }
        Group {
            if isDownloaded {
                Menu {
                    Button("Delete Download", systemImage: "trash", role: .destructive) {
                        if let item { downloads.deleteDownloads(ofItem: item.id) }
                    }
                } label: {
                    // A check in the accent color, which tells it from Download at a glance.
                    Label {
                        Text("Downloaded")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .help("Downloaded")
            } else if let job = jobs.first {
                Menu {
                    if job.status == .failed {
                        Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }
                    }
                    Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
                } label: {
                    if job.status == .failed {
                        Label("Download Failed", systemImage: "exclamationmark.circle")
                    } else {
                        Label {
                            Text("Downloading")
                        } icon: {
                            DownloadRing(job: job)
                        }
                    }
                }
                .accessibilityValue(job.status == .failed ? "" : DownloadRing.spokenProgress(of: job, downloads: downloads))
                .help(job.status == .failed ? "Download Failed" : "Downloading")
            } else {
                Button {
                    download()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(item == nil)
                .help("Download")
            }
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .animation(.default, value: isDownloaded)
        .sensoryFeedback(trigger: isDownloaded) { was, now in now && !was ? .success : nil }
        .accessibilityIdentifier("detail.download")
    }

    private func download() {
        guard let item else { return }
        Task {
            if let problem = await downloads.download(item, picked: source, settings: settings) { messages.show(problem) }
        }
    }
}

/// A download's progress as a ring.
struct DownloadRing: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads
    /// As wide as a line of body text, growing with it.
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 18

    var body: some View {
        let fraction = Self.fraction(of: job, downloads: downloads)
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
            Circle().trim(from: 0, to: fraction).stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down").font(.system(size: diameter * 0.44, weight: .bold))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue(Self.spokenProgress(of: job, downloads: downloads))
    }

    static func fraction(of job: DownloadJob, downloads: DownloadManager) -> Double {
        let received = downloads.receivedBytes[job.id] ?? job.bytesOnDisk
        return job.displayTotalBytes.map { $0 > 0 ? Double(received) / Double($0) : 0 } ?? 0
    }

    /// "40 percent".
    static func spokenProgress(of job: DownloadJob, downloads: DownloadManager) -> String {
        "\(Int(fraction(of: job, downloads: downloads) * 100)) percent"
    }
}
#endif
