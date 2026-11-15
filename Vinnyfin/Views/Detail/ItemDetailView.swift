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
    @Environment(ServerReachability.self) private var reachability
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    /// Another episode of the show, picked on the page, that it shows in place of `item`.
    @State private var picked: JellyfinItem?
    @State private var detail: JellyfinItem?
    /// Titles like it, its genres and its collections: an episode's show's.
    @State private var related = RelatedTitles()
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

    /// The title's finished download, which Play plays unless another version is picked, as
    /// `PlaybackResolver` does.
    private var downloadedVersion: DownloadedVersion? {
        #if os(tvOS)
        nil
        #else
        downloads.jobs(forItem: page.id).first { $0.status == .completed }.map { job in
            DownloadedVersion(sourceId: job.mediaSourceId, transcode: job.transcode?.label, size: job.displayTotalBytes)
        }
        #endif
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
                DetailHero(item: shown, eyebrow: shown.isEpisode ? shown.seriesName : nil, showLink: series,
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
                    } else if let loadError, !reachability.isOutOfReach {
                        LoadFailureNotice(loadError) { Task { await load() } }
                            .padding(.horizontal, Metrics.edge)
                    }
                    if !isGone, shown.isNotYetAvailable() { notYetAvailableNote }
                    if !isGone || isDownloaded, !shown.isNotYetAvailable() {
                        OfflinePlayNote(item: shown, mediaSourceId: pickedSourceId)
                    }
                    OverviewText(item: shown).padding(.horizontal, Metrics.edge)
                    if detail != nil {
                        TitleLinks(genres: related.genres(of: shown), collections: related.collections)
                            #if os(tvOS)
                            .pageRow("links", in: rowLayout)
                            #endif
                    }
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
                    if !related.similar.isEmpty {
                        MoreLikeThisShelf(related: $related)
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
        // The server answering again, after it was out of reach.
        .onChange(of: reachability.isOutOfReach) { _, isOutOfReach in
            if !isOutOfReach { Task { await load() } }
        }
        // A playback that ended moved where the title resumes, or finished it.
        .onChange(of: player.endedPlayback) {
            related.similar = player.endedPlayback.applied(to: related.similar)
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

    /// Without the title on the server, only what its download still does. On Apple TV an
    /// episode's leads to its show, as its logo does elsewhere.
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
            #if os(tvOS)
            if let series { GoToShowButton(show: series) }
            #endif
            if available {
                SharePlayButton(subject: .title(shown, mediaSourceId: pickedSourceId))
            }
            if available, sources.count > 1 {
                let downloaded = downloadedVersion
                VersionMenu(sources: sources,
                            selection: Binding(get: { pickedSourceId ?? downloaded?.sourceId ?? playbackSource?.id },
                                               set: { pickedSourceId = $0 }),
                            downloaded: downloaded)
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

    /// The episode's show, which its logo or name leads to, opened on the episode's season. From
    /// the details: a link names only the episode.
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
        if !sameTitle { related = RelatedTitles() }
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

    /// The details and what's around the title: titles like it, its genres and its collections.
    /// Refreshing asks for both again, and has the season row reload its episodes. While the server
    /// is out of reach the page keeps what it shows, and loads once the server answers; refreshing
    /// asks it whether it does.
    private func load(refreshing: Bool = false) async {
        guard !reachability.isOutOfReach else {
            if refreshing { await reachability.check() }
            return
        }
        if refreshing { reloads += 1 }
        await loadDetail()
        guard let session, !isGone, !reachability.isOutOfReach, refreshing || related.titleId != page.titleId else { return }
        do {
            related = try await RelatedTitles.load(for: detail ?? page, client: session.client, userId: session.userId,
                                                   length: MoreLikeThisShelf.length)
        } catch {
            guard !error.isCancellation else { return }
            related = RelatedTitles()
            loadError = loadError ?? LoadFailure("Couldn't Load Titles Like This", error: error)
        }
    }

    private func loadDetail() async {
        guard let session, !reachability.isOutOfReach else { return }
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
            // Out of reach, the page says so under Play rather than this.
            await reachability.check()
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

/// Marks the button of a title's action row that takes up the rest of its row, Play, once the
/// buttons don't all fit on one: on a phone, the full width of the page but for Start Over.
nonisolated struct WidensTitleAction: LayoutValueKey {
    static let defaultValue = false
}

extension VerticalAlignment {
    /// The middle of a title action's button, above any caption under it, which the buttons in a
    /// row of them line up by.
    nonisolated static let titleAction = VerticalAlignment(TitleActionMiddle.self)
}

nonisolated private enum TitleActionMiddle: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

/// The buttons over a title's artwork: all in one row when they fit, or else Play's on a row above
/// the rest's (`SecondaryTitleAction`), each going on to more rows as it needs, which at the
/// largest text sizes puts one button on each. On rows of their own, Play widens to the rest of its
/// row (`WidensTitleAction`). In a row the buttons line up by their middles, their captions under
/// them (`VerticalAlignment.titleAction`). A layout rather than a choice of stacks keeps each
/// button the same view however they're laid out, so focus stays on Play as the row rearranges,
/// such as when Start Over joins it.
struct TitleActionsLayout: Layout {
    var spacing: CGFloat = 12

    private struct Placement {
        let index: Int
        var size: CGSize
        /// How far down the button's middle is.
        var middle: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width)
        let width = lines.map { line in line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1)) }.max() ?? 0
        let height = lines.reduce(0) { $0 + lineHeight($1).total } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            let height = lineHeight(line)
            var x = bounds.minX
            for placement in line {
                subviews[placement.index].place(at: CGPoint(x: x, y: y + height.middle - placement.middle),
                                                proposal: ProposedViewSize(placement.size))
                x += placement.size.width + spacing
            }
            y += height.total + spacing
        }
    }

    /// A line's height, and how far down the middles of its buttons are.
    private func lineHeight(_ line: [Placement]) -> (total: CGFloat, middle: CGFloat) {
        let above = line.map(\.middle).max() ?? 0
        let below = line.map { $0.size.height - $0.middle }.max() ?? 0
        return (above + below, above)
    }

    private func placement(_ index: Int, of subview: LayoutSubview, size: CGSize) -> Placement {
        Placement(index: index, size: size, middle: subview.dimensions(in: ProposedViewSize(size))[.titleAction])
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [[Placement]] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = width ?? .infinity
        let oneRow = ideal.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, ideal.count - 1))
        if oneRow <= available {
            return [subviews.indices.map { placement($0, of: subviews[$0], size: ideal[$0]) }]
        }
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
            line.append(placement(index, of: subview, size: size))
        }
        if !line.isEmpty { lines.append(line) }
        guard available.isFinite else { return lines }
        return lines.map { widened($0, subviews: subviews, available: available) }
    }

    /// `line` with its widening button, if it has one, taking up the rest of the row.
    private func widened(_ line: [Placement], subviews: Subviews, available: CGFloat) -> [Placement] {
        guard let position = line.firstIndex(where: { subviews[$0.index][WidensTitleAction.self] }) else { return line }
        let used = line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1))
        guard available - used > 1 else { return line }
        var line = line
        let index = line[position].index
        let width = line[position].size.width + available - used
        let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        line[position] = placement(index, of: subviews[index], size: CGSize(width: max(size.width, line[position].size.width), height: size.height))
        return line
    }
}

/// Play, or Resume with the time left over a track of how far it got, plus Start Over beside it
/// when there's a position.
struct PlayButton: View {
    let item: JellyfinItem
    var mediaSourceId: String?
    #if os(tvOS)
    /// Play's focus, which the page starts on.
    let focus: FocusState<Bool>.Binding
    #endif
    @Environment(PlayerCoordinator.self) private var player
    private let playable = PlayableNow(isDownloaded: nil)

    var body: some View {
        Button {
            guard playable(item, mediaSourceId: mediaSourceId) else { return }
            player.play(.item(item, mediaSourceId: mediaSourceId, loaded: item))
        } label: {
            PlayLabel(title: label, progress: item.resumeSeconds != nil ? item.progress : nil)
        }
        .buttonStyle(.platformGlassProminent)
        .controlSize(.large)
        .accessibilityLabel(spokenLabel)
        .accessibilityInputLabels([item.resumeSeconds != nil ? "Resume" : "Play", label])
        .accessibilityIdentifier("detail.play")
        #if os(tvOS)
        // Focusable while it can't play, the server being out of reach, so focus can start on it:
        // a page opened then has nothing else to focus, and the remote's Back would do nothing.
        .opacity(playable(item, mediaSourceId: mediaSourceId) ? 1 : 0.5)
        .accessibilityHint(OfflinePlayability.reason(for: item, server: playable.serverTitle),
                           isEnabled: !playable(item, mediaSourceId: mediaSourceId))
        .focused(focus)
        #else
        .playableOffline(item, mediaSourceId: mediaSourceId)
        #endif
        .layoutValue(key: WidensTitleAction.self, value: true)
        if item.resumeSeconds != nil {
            Button {
                player.play(.item(item, mediaSourceId: mediaSourceId, fromBeginning: true, loaded: item))
            } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
            }
            .titleActionStyle()
            .actionCaption("Start Over")
            .help("Start Over")
            .accessibilityIdentifier("detail.startOver")
            .playableOffline(item, mediaSourceId: mediaSourceId)
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

/// Play's words with its symbol, at least as wide as a short title's, and as wide as its row lets
/// it be (`WidensTitleAction`); under them, for a resume, a thin track of how far it got.
struct PlayLabel: View {
    let title: String
    /// How far a resume got, 0...1; nil for a play from the start.
    var progress: Double?
    var systemImage = "play.fill"

    var body: some View {
        VStack(spacing: 5) {
            Label(title, systemImage: systemImage)
            if let progress {
                Capsule()
                    .fill(.foreground.opacity(0.25))
                    .overlay(alignment: .leading) {
                        GeometryReader { track in
                            Capsule().fill(.foreground).frame(width: max(3, track.size.width * min(1, max(0, progress))))
                        }
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 120, maxWidth: .infinity)
    }
}

/// Marks a title watched or unwatched. A whole show or season asks first, saying how many
/// episodes that is, and then offers Undo (`WatchActions.setPlayedAfterAsking`). Off while the
/// server is out of reach.
struct WatchedButton: View {
    let item: JellyfinItem
    /// Told of the change as it's made, and again of the item as it was if the server refuses it.
    let onChange: (JellyfinItem) -> Void
    /// Called once the server has the change, for what it changed besides the item, such as a
    /// show's episodes; and again once Undo has put them back.
    var afterChange: () async -> Void = {}
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages
    /// Counts the presses, for the haptic: the state also changes as a playback ends.
    @State private var presses = 0

    var body: some View {
        Button(action: press) {
            Label {
                Text("Watched")
            } icon: {
                Image(systemName: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                    .modifier(StateSymbol(isOn: item.isPlayed))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .titleActionStyle()
        .sensoryFeedback(.selection, trigger: presses)
        .actionCaption(item.isPlayed ? "Watched" : "Mark Watched")
        .help(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")
        // To VoiceOver and Voice Control a switch named Watched, on when watched. The button as
        // drawn would always read as on: SwiftUI takes a checkmark symbol for a selection.
        .accessibilityRepresentation {
            Toggle("Watched", isOn: Binding(get: { item.isPlayed }, set: { _ in press() }))
        }
        .accessibilityIdentifier("detail.watched")
        .needsServer()
    }

    private func press() {
        presses += 1
        Task { await toggle() }
    }

    private func toggle() async {
        guard let session else { return }
        if WatchActions.marksManyEpisodes(item) {
            await WatchActions.setPlayedAfterAsking(!item.isPlayed, on: item, session: session, messages: messages,
                                                    onChange: onChange, afterChange: afterChange)
        } else {
            await WatchActions.setPlayed(!item.isPlayed, on: item, session: session, messages: messages, onChange: onChange)
            await afterChange()
        }
    }
}

/// The symbol of a round action that shows a state, as Watched and Favorite do: in the accent while
/// the state is on. Its color is its own, so it doesn't fade with the button's when the button is
/// turned off, as the other actions' symbols do: it fades here instead.
private struct StateSymbol: ViewModifier {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.foreground))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Adds a title to the favorites or takes it out. Off while the server is out of reach.
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
            Label {
                Text("Favorite")
            } icon: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    .modifier(StateSymbol(isOn: item.isFavorite))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: additions)
            }
        }
        .titleActionStyle()
        .sensoryFeedback(.selection, trigger: presses)
        .actionCaption(item.isFavorite ? "Favorited" : "Favorite")
        .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        // To VoiceOver and Voice Control a switch named Favorite, on when it's one.
        .accessibilityRepresentation {
            Toggle("Favorite", isOn: Binding(get: { item.isFavorite }, set: { _ in press() }))
        }
        .accessibilityIdentifier("detail.favorite")
        .needsServer()
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

#if os(tvOS)
/// An episode's show, from its page's buttons: on Apple TV the show's logo over the episode isn't
/// a button, which would put a stray stop for focus above Play.
struct GoToShowButton: View {
    let show: JellyfinItem

    var body: some View {
        NavigationLink(value: show) {
            Label("Go to Show", systemImage: "tv")
        }
        .titleActionStyle()
        .actionCaption("Go to Show")
        .accessibilityHint("Opens \(show.seriesName ?? show.name)")
        .accessibilityIdentifier("detail.eyebrow")
    }
}
#endif

extension View {
    /// A round button of a title's actions: its symbol on glass, its name for VoiceOver and the
    /// Mac's help tag.
    func titleActionStyle() -> some View {
        buttonStyle(.platformGlass)
            .controlSize(.large)
            .labelStyle(TitleActionLabelStyle())
            .buttonBorderShape(.circle)
    }

    /// What a round button of a title's actions does or is, in a word or two under it, so no
    /// button is a bare symbol and a state shows in words as well as in its symbol's fill.
    func actionCaption(_ caption: String) -> some View {
        modifier(ActionCaption(caption: caption))
    }
}

/// A round button's symbol alone, in the room a round symbol takes, so a wide one such as Play
/// On's makes no bigger a circle than the rest. Its title stays its name for VoiceOver.
private struct TitleActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            Image(systemName: "circle").hidden()
                .overlay { configuration.icon }
        }
        .labelStyle(.iconOnly)
    }
}

private struct ActionCaption: ViewModifier {
    let caption: String
    /// The buttons are over the hero's artwork, on its dark, in either appearance.
    @Environment(\.actionsOverArtwork) private var overArtwork

    func body(content: Content) -> some View {
        VStack(spacing: Self.gap) {
            content
                .alignmentGuide(.titleAction) { $0[VerticalAlignment.center] }
            Text(caption)
                .font(Self.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .environment(\.colorScheme, overArtwork ? .dark : colorScheme)
                // The button's name already says it.
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private static var font: Font {
        #if os(tvOS)
        .caption.weight(.medium)
        #else
        .caption2.weight(.medium)
        #endif
    }

    /// Between the button and its caption; on Apple TV clear of the button as focus lifts it.
    private static var gap: CGFloat {
        #if os(tvOS)
        14
        #else
        6
        #endif
    }
}

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
        .titleActionStyle()
        .animation(.default, value: isDownloaded)
        .sensoryFeedback(trigger: isDownloaded) { was, now in now && !was ? .success : nil }
        .actionCaption(isDownloaded ? "Downloaded" : jobs.first.map { $0.status == .failed ? "Failed" : "Downloading" } ?? "Download")
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
