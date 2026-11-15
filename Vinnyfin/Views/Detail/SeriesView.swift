import AppIntents
import SwiftUI

/// A show: play the next episode, or once it's all watched, watch it again from the first; shuffle
/// it; download a season or all of it, keep it downloaded, and its episodes one season at a time,
/// starting on the season being watched. Select turns the episodes into checkboxes for downloading
/// several at once, or marking them watched or unwatched.
struct SeriesView: View {
    let series: JellyfinItem
    var initialSeasonId: String?

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.openTitle) private var openTitle
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ServerReachability.self) private var reachability
    #if !os(tvOS)
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadManager.self) private var downloads
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var detail: JellyfinItem?
    @State private var seasons: [JellyfinItem] = []
    @State private var seasonId: String?
    /// The episodes listed, of `episodesSeasonId`: while another season's load, the last one's.
    @State private var episodes: [JellyfinItem]?
    @State private var episodesSeasonId: String?
    /// The episodes of each season loaded so far, which show at once as their season is picked
    /// again, while they load again.
    @State private var loaded: [String: [JellyfinItem]] = [:]
    @State private var nextUp: JellyfinItem?
    /// Up Next has answered, with an episode or with none.
    @State private var nextUpLoaded = false
    /// With nothing next, the show's first episode, which Play plays instead: Watch Again, for a
    /// show watched up to its latest episode.
    @State private var firstEpisode: JellyfinItem?
    /// The first episode was looked for, found or not, since nothing came next.
    @State private var firstEpisodeLoaded = false
    /// Shows like it, its genres and its collections.
    @State private var related = RelatedTitles()
    @State private var loadError: LoadFailure?
    /// The server answered that it doesn't have the show, which asking again won't change.
    @State private var isGone = false
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var batch: Batch?
    /// On screen, rather than under a page pushed over it or in another tab.
    @State private var isOnScreen = false
    @FocusState private var focusedEpisode: String?
    #if os(tvOS)
    /// The episodes the list holds.
    @State private var episodeWindow = FocusWindow()
    /// The episode at the top of the screen, kept there as the window moves.
    @State private var position = ScrollPosition(idType: String.self)
    @FocusState private var playFocused: Bool
    /// Bounds the page's default focus.
    @Namespace private var focusScope
    #endif

    struct Batch: Identifiable {
        let id = UUID()
        let episodes: [JellyfinItem]
    }

    private var shown: JellyfinItem { detail ?? series }

    /// The season shown's episodes, once they're the ones listed.
    private var currentEpisodes: [JellyfinItem]? { episodesSeasonId == seasonId ? episodes : nil }

    /// Another season's episodes are on their way, and the last one's stand dimmed in their place.
    private var isSwitching: Bool { episodes != nil && episodesSeasonId != seasonId }

    /// What Play plays: the episode next, or with none, the first again.
    private var playTarget: JellyfinItem? { nextUp ?? firstEpisode }

    /// Nothing is next, though some of the show was watched: Play starts it over.
    private var watchesAgain: Bool {
        nextUp == nil && firstEpisode != nil && (shown.isPlayed || (shown.userData?.playedPercentage ?? 0) > 0)
    }

    /// It's known what Play plays, or that there's nothing.
    private var playSettled: Bool { nextUpLoaded && (nextUp != nil || firstEpisodeLoaded) }

    /// The show's seasons but for its specials, which say whether Play names the season.
    private var seasonCount: Int { seasons.count { ($0.indexNumber ?? 0) > 0 } }

    /// Play stands in place, unable to play, until it's known what it plays, so the buttons don't
    /// move as it comes; and on Apple TV, so focus starts on it rather than on a switch that
    /// would mark the whole show. With nothing to play it goes once the episodes are in, for
    /// focus to go to the first of them.
    private var showsPlay: Bool {
        guard !isGone else { return false }
        return playTarget != nil || !playSettled || (episodes == nil && loadError == nil)
    }

    var body: some View {
        EdgeToEdgeScrollView(underTopBars: true) {
            VStack(alignment: .leading, spacing: 24) {
                DetailHero(item: shown) { actions }
                VStack(alignment: .leading, spacing: 24) {
                    if isGone {
                        TitleGoneNotice()
                            .padding(.horizontal, Metrics.edge)
                    } else if let loadError, !reachability.isOutOfReach {
                        LoadFailureNotice(loadError) { Task { await retry() } }
                            .padding(.horizontal, Metrics.edge)
                    }
                    if showsPlay { OfflinePlayNote(item: playTarget ?? shown, mediaSourceId: nil) }
                    OverviewText(item: shown).padding(.horizontal, Metrics.edge)
                    if detail != nil {
                        TitleLinks(genres: related.genres(of: shown), collections: related.collections)
                    }
                    if !isGone {
                        VStack(alignment: .leading, spacing: 12) {
                            // Also over a single season's episodes, which have no chips.
                            Text("Episodes")
                                .font(.title3.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, Metrics.edge)
                            seasonPicker
                            episodeList
                        }
                    }
                    if let detail {
                        CastAndCrewShelf(credits: Credits(people: detail.people ?? []))
                        TitleExtrasShelf(item: detail)
                    }
                    if !related.similar.isEmpty { MoreLikeThisShelf(related: $related) }
                    if !isGone { TitleInformation(item: shown, source: nil, credits: Credits(people: detail?.people ?? [])) }
                }
                .padding(.bottom, Metrics.edge)
            }
        }
        #if os(tvOS)
        .scrollPosition($position, anchor: .top)
        .onScrollPhaseChange { _, phase in
            if phase == .idle, let episodes, let index = episodes.firstIndex(where: { $0.id == focusedEpisode }) {
                episodeWindow.follow(index, count: episodes.count)
            }
        }
        #endif
        .refreshable { await refresh() }
        .pageBackground()
        .screenTitle(series.name)
        .inlineNavigationTitle()
        .heroScrollEdge()
        .handoffPage(shown)
        #if !os(tvOS)
        .toolbar { selectionToolbar }
        #if os(iOS)
        // On iPhone the tabs make way for the bar along the bottom with Mark in it, as in Photos;
        // on iPad they're at the top, out of its way.
        .toolbarVisibility(isSelecting && horizontalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        #endif
        .sheet(item: $batch) { batch in
            BatchDownloadSheet(episodes: batch.episodes) {
                isSelecting = false
                selection.removeAll()
            }
        }
        #else
        // Focus starts on Play, also for a page opened from a link at launch, or with nothing
        // next, on the first episode; never on a switch, which a reflexive press would flip for
        // the whole show. Coming back to the page leaves focus where it was.
        .focusScope(focusScope)
        .defaultFocus($playFocused, true)
        .defaultFocus($focusedEpisode, showsPlay ? nil : episodes?.first?.id)
        // Nothing next after all: from Play's stand-in to the first episode, rather than to
        // whatever is nearest as it goes.
        .onChange(of: showsPlay) { _, shows in
            if !shows, playFocused { focusedEpisode = episodes?.first?.id }
        }
        #endif
        // Siri knows which show the page is about: "continue watching this".
        .appEntityIdentifier(EntityIdentifier.title(series))
        .task(id: series.id) { await load() }
        .task(id: seasonId) { await loadEpisodes() }
        // The server answering again, after it was out of reach.
        .onChange(of: reachability.isOutOfReach) { _, isOutOfReach in
            if !isOutOfReach { Task { await retry() } }
        }
        .onChange(of: player.endedPlayback) {
            related.similar = player.endedPlayback.applied(to: related.similar)
            Task { await reloadWatchState() }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        // Back in the app, what was watched elsewhere in the meantime.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isOnScreen, !isGone { Task { await reloadWatchState() } }
        }
    }

    // MARK: Actions

    /// Play and Shuffle, then the rest: in one row, or where that doesn't fit, Play's on a row
    /// above the rest's.
    private var actions: some View {
        TitleActionsLayout {
            if showsPlay {
                playButton
                shuffleButton
            }
            if !isGone {
                Group { secondaryButtons }
                    .layoutValue(key: SecondaryTitleAction.self, value: true)
            }
        }
    }

    /// The next episode's Play, or with none, the first's, as Watch Again once the show's been
    /// watched; until it's known, Play standing in for it, which plays nothing. It's the same
    /// button throughout, so focus stays on it as the episode comes. While the server is out of
    /// reach it's off, but for an episode that's downloaded.
    private var playButton: some View {
        let label = playTarget.map { watchesAgain ? "Watch Again" : ShowPlayback.playLabel(for: $0, seasons: seasonCount) } ?? "Play"
        return Button {
            guard let playTarget else { return }
            player.play(.item(playTarget, fromBeginning: watchesAgain))
        } label: {
            PlayLabel(title: label, progress: playTarget?.resumeSeconds != nil ? playTarget?.progress : nil,
                      systemImage: watchesAgain ? "arrow.counterclockwise" : "play.fill")
        }
        .buttonStyle(.platformGlassProminent)
        .controlSize(.large)
        #if os(tvOS)
        // Still focusable, so focus can start on it.
        .opacity(playTarget == nil ? 0.5 : 1)
        #else
        .disabled(playTarget == nil)
        #endif
        .playableOffline(playTarget ?? shown)
        .accessibilityLabel(playTarget.map { watchesAgain ? "Watch again from the start" : ShowPlayback.spokenPlayLabel(for: $0, seasons: seasonCount) } ?? "Play")
        .accessibilityInputLabels(playTarget.map { [watchesAgain ? "Watch Again" : $0.resumeSeconds != nil ? "Resume" : "Play", label] } ?? ["Play"])
        .accessibilityIdentifier("series.play")
        #if os(tvOS)
        .focused($playFocused)
        #endif
        .layoutValue(key: WidensTitleAction.self, value: true)
    }

    /// The show's episodes in an order of their own, which Next, Previous and autoplay follow.
    private var shuffleButton: some View {
        Button {
            guard let session else { return }
            Task { await ShowPlayback.shuffle(shown, session: session, player: player, messages: messages) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        .titleActionStyle()
        .actionCaption("Shuffle")
        .help("Shuffle")
        .accessibilityIdentifier("series.shuffle")
        // It asks the server for all the show's episodes to shuffle.
        .playableOffline(shown)
    }

    @ViewBuilder private var secondaryButtons: some View {
        #if !os(tvOS)
        smartDownloadMenu
        #endif
        // Marking the show marks every episode, which the list then shows.
        WatchedButton(item: shown) { detail = $0 } afterChange: { await reloadWatchState() }
        FavoriteButton(item: shown) { detail = $0 }
        if let playTarget {
            PlayElsewhereButton(subject: .title(playTarget, mediaSourceId: nil))
        }
    }

    #if !os(tvOS)
    /// Downloads now, of the season shown or the whole show, through the batch sheet's choice of
    /// versions and its size; and the ways to keep the show downloaded.
    private var smartDownloadMenu: some View {
        let rule = smartDownloads.rule(for: series.id)
        let title = rule == nil ? "Download" : "Smart Download On"
        return SmartDownloadMenu(seriesId: series.id, seriesName: series.name) {
            Section("Download Now") {
                if let season = seasons.first(where: { $0.id == seasonId }) {
                    let missing = notDownloaded(currentEpisodes ?? [])
                    Button(missing.isEmpty && currentEpisodes != nil ? "\(season.name) Is Downloaded" : "Download \(season.name)",
                           systemImage: "arrow.down.circle") {
                        batch = Batch(episodes: missing)
                    }
                    .disabled(missing.isEmpty)
                    .accessibilityIdentifier("series.downloadSeason")
                }
                Button("Download Every Episode", systemImage: "square.stack.3d.down.forward") {
                    Task { await downloadEveryEpisode() }
                }
                .accessibilityIdentifier("series.downloadSeries")
            }
        } label: {
            Label(title, systemImage: rule == nil ? "arrow.down.circle" : "sparkles.rectangle.stack.fill")
        }
        .titleActionStyle()
        .actionCaption(rule == nil ? "Download" : "Smart Download")
        .help(title)
        .accessibilityIdentifier("series.smartDownload")
    }

    /// The episodes without a download in any state.
    private func notDownloaded(_ episodes: [JellyfinItem]) -> [JellyfinItem] {
        episodes.filter { downloads.jobs(forItem: $0.id).isEmpty }
    }

    /// Every episode of every season, specials left out, that isn't downloaded or on its way.
    private func downloadEveryEpisode() async {
        guard let session else { return }
        do {
            let all = try await session.client.episodes(seriesId: series.id, seasonId: nil, userId: session.userId,
                                                        fields: "PrimaryImageAspectRatio")
            batch = Batch(episodes: notDownloaded(all.filter { $0.parentIndexNumber != 0 }))
        } catch {
            messages.show("Couldn't load the episodes of \(series.name): \(error.localizedDescription)")
        }
    }

    @ToolbarContentBuilder private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .barPinnedTrailing) {
            if isSelecting {
                Button("Done") {
                    isSelecting = false
                    selection.removeAll()
                }
                .accessibilityIdentifier("series.done")
            } else {
                Button("Select", systemImage: "checklist") { isSelecting = true }
                    .disabled(currentEpisodes?.isEmpty ?? true)
                    .accessibilityIdentifier("series.select")
            }
        }
        if isSelecting {
            ToolbarItem(placement: .barTrailing) {
                let allIds = Set(currentEpisodes?.map(\.id) ?? [])
                if !allIds.isEmpty, selection == allIds {
                    Button("Deselect All") { selection.removeAll() }
                } else {
                    Button("Select All") { selection = allIds }
                        .accessibilityIdentifier("series.selectAll")
                }
            }
            ToolbarItem(placement: .barTrailing) {
                // Text rather than an icon: bars show only the icon, and the count would be lost.
                Button("Download \(selection.count)") {
                    batch = Batch(episodes: selectedEpisodes)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("series.download")
            }
            ToolbarItem(placement: markPlacement) {
                Menu {
                    Button("Mark \(selectionCount) as Watched", systemImage: "checkmark.circle") {
                        Task { await markSelected(true) }
                    }
                    Button("Mark \(selectionCount) as Unwatched", systemImage: "circle") {
                        Task { await markSelected(false) }
                    }
                } label: {
                    Label("Mark Watched or Unwatched", systemImage: "checkmark.circle")
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("series.mark")
            }
        }
    }

    /// Along the bottom on iPhone and iPad, where the top bar has no room for it beside Select
    /// All, Download and Done, and on iPad the tabs; with them elsewhere.
    private var markPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .barTrailing
        #endif
    }

    private var selectedEpisodes: [JellyfinItem] {
        (currentEpisodes ?? []).filter { selection.contains($0.id) }
    }

    /// "1 Episode", "3 Episodes".
    private var selectionCount: String {
        selection.count == 1 ? "1 Episode" : "\(selection.count) Episodes"
    }

    /// Marks the episodes picked, and ends the picking.
    private func markSelected(_ played: Bool) async {
        guard let session else { return }
        let picked = selectedEpisodes
        isSelecting = false
        selection.removeAll()
        await WatchActions.setPlayed(played, episodes: picked, showName: series.name, session: session, messages: messages) {
            await reloadWatchState()
        }
    }
    #endif

    // MARK: Seasons and episodes

    private var seasonPicker: some View {
        SeasonPicker(seasons: seasons, selection: $seasonId) { season in
            Button(season.isPlayed ? "Mark \(season.name) as Unwatched" : "Mark \(season.name) as Watched",
                   systemImage: season.isPlayed ? "eye.slash" : "eye") {
                Task { await setPlayed(!season.isPlayed, season: season) }
            }
        }
    }

    @ViewBuilder private var episodeList: some View {
        if let episodes {
            LazyVStack(alignment: .leading, spacing: 16) {
                #if os(tvOS)
                // The episodes around focus; see `FocusWindow`.
                ForEach(episodes[episodeWindow.range(count: episodes.count)]) { episodeRow($0) }
                #else
                ForEach(episodes) { episodeRow($0) }
                #endif
            }
            #if os(tvOS)
            .scrollTargetLayout()
            #endif
            .padding(.horizontal, Metrics.edge)
            .opacity(isSwitching ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.2), value: isSwitching)
            #if os(tvOS)
            .focusSection()
            #endif
        } else if reachability.isOutOfReach {
            Label("The episodes show when vinnyfin can reach \(session?.account.serverTitle ?? "the server") again.",
                  systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.edge)
        } else if loadError == nil {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func episodeRow(_ episode: JellyfinItem) -> some View {
        EpisodeRow(
            episode: episode,
            isSelecting: isSelecting,
            isSelected: selection.contains(episode.id),
            isNext: episode.id == nextUp?.id,
            focus: $focusedEpisode,
            openPage: { openTitle?(episode) },
            afterBatchChange: { await reloadWatchState() }
        ) {
            if isSelecting {
                if selection.contains(episode.id) { selection.remove(episode.id) } else { selection.insert(episode.id) }
            } else if episode.isNotYetAvailable() {
                // Nothing to play yet: its page says when it airs.
                openTitle?(episode)
            } else {
                player.play(.item(episode))
            }
        } onChange: { updated in
            if let index = episodes?.firstIndex(where: { $0.id == updated.id }) { episodes?[index] = updated }
            for key in loaded.keys {
                if let index = loaded[key]?.firstIndex(where: { $0.id == updated.id }) { loaded[key]?[index] = updated }
            }
        }
    }

    // MARK: Loading

    /// While the server is out of reach, the page keeps what it shows, and loads once it answers.
    private func load() async {
        guard let session, !reachability.isOutOfReach else { return }
        loadError = nil
        do {
            async let detail = session.client.item(id: series.id, userId: session.userId)
            async let seasons = session.client.seasons(seriesId: series.id, userId: session.userId)
            async let nextUp = session.client.upNext(seriesId: series.id, userId: session.userId)
            async let lastWatched = session.client.finishedEpisodes(userId: session.userId, seriesId: series.id, limit: 1)
            self.detail = try await detail
            let found = try await seasons
            self.seasons = found
            let next = try await nextUp
            self.nextUp = next
            nextUpLoaded = true
            isGone = false
            if seasonId == nil {
                seasonId = ShowPlayback.initialSeason(in: found, requested: initialSeasonId, next: next,
                                                      lastWatched: (try? await lastWatched)?.first)
            }
            await settleFirstEpisode(session: session)
        } catch JellyfinError.http(let status, _) where status == 404 {
            isGone = true
            detail = nil
            return
        } catch {
            guard !error.isCancellation else { return }
            loadError = LoadFailure("Couldn't Load the Show", error: error)
            // Out of reach, the page waits for the server rather than say this.
            await reachability.check()
            if reachability.isOutOfReach { return }
        }
        do {
            related = try await RelatedTitles.load(for: detail ?? series, client: session.client, userId: session.userId,
                                                   length: MoreLikeThisShelf.length)
        } catch {
            guard !error.isCancellation else { return }
            related = RelatedTitles()
            loadError = loadError ?? LoadFailure("Couldn't Load Shows Like This", error: error)
        }
    }

    /// The season picked's episodes: at once if they loaded before, then as they are now. Until
    /// they come, the last season's stay listed, dimmed, so the page keeps its place.
    private func loadEpisodes() async {
        guard let session, let seasonId, !reachability.isOutOfReach else { return }
        selection.removeAll()
        if episodesSeasonId != seasonId, let known = loaded[seasonId] { show(known, of: seasonId) }
        do {
            let found = try await seasonEpisodes(seasonId, session: session)
            guard seasonId == self.seasonId else { return }
            show(found, of: seasonId)
        } catch {
            if !error.isCancellation { loadError = LoadFailure("Couldn't Load the Episodes", error: error) }
        }
    }

    /// Puts a season's episodes in the list, fading from the last season's.
    private func show(_ found: [JellyfinItem], of seasonId: String) {
        loaded[seasonId] = found
        guard found != episodes || episodesSeasonId != seasonId else { return }
        #if os(tvOS)
        if episodesSeasonId != seasonId { episodeWindow = FocusWindow() }
        #endif
        withAnimation(.easeInOut(duration: 0.25)) {
            episodes = found
            episodesSeasonId = seasonId
        }
    }

    /// What a playback that ended, or a change to the whole show, changed: the show's watched
    /// state, where it goes on, the seasons' watched states, and the season's episodes, kept on
    /// screen and selected as they are while they load.
    private func reloadWatchState() async {
        guard let session, !reachability.isOutOfReach else { return }
        do {
            async let detail = session.client.item(id: series.id, userId: session.userId)
            async let nextUp = session.client.upNext(seriesId: series.id, userId: session.userId)
            async let seasons = session.client.seasons(seriesId: series.id, userId: session.userId)
            try await reloadSeason(session: session)
            self.detail = try await detail
            self.nextUp = try await nextUp
            nextUpLoaded = true
            self.seasons = try await seasons
            await settleFirstEpisode(session: session)
        } catch {
            guard !error.isCancellation else { return }
            loadError = LoadFailure("Couldn't Load the Show", error: error)
        }
    }

    /// With nothing next, finds the first episode for Play to play instead.
    private func settleFirstEpisode(session: ServerSession) async {
        guard nextUp == nil else { return }
        if firstEpisode == nil {
            firstEpisode = try? await ShowPlayback.firstEpisode(of: series.id, seasons: seasons, session: session)
        }
        firstEpisodeLoaded = true
    }

    /// Marks a whole season watched or not, once asked, then shows what that changed, and again
    /// after an Undo.
    private func setPlayed(_ played: Bool, season: JellyfinItem) async {
        guard let session else { return }
        var season = season
        if season.seriesName == nil { season.seriesName = series.name }
        await WatchActions.setPlayedAfterAsking(played, on: season, session: session, messages: messages) { updated in
            if let index = seasons.firstIndex(where: { $0.id == updated.id }) { seasons[index] = updated }
        } afterChange: {
            await reloadWatchState()
        }
    }

    /// Everything that didn't load, again: the show, and the season's episodes if they didn't come.
    private func retry() async {
        await load()
        if currentEpisodes == nil { await loadEpisodes() }
    }

    /// The season shown's episodes as they are now. The other seasons' load again as they're
    /// picked: what changed may have changed them too, as marking a show watched does.
    private func reloadSeason(session: ServerSession) async throws {
        guard let seasonId else { return }
        let found = try await seasonEpisodes(seasonId, session: session)
        loaded = loaded.filter { $0.key == seasonId }
        if seasonId == self.seasonId { show(found, of: seasonId) }
    }

    /// Pulled down: all of the page again, the season's episodes as they are now too. While the
    /// server is out of reach, whether it answers now.
    private func refresh() async {
        guard !reachability.isOutOfReach else {
            await reachability.check()
            return
        }
        await load()
        guard let session, !isGone else { return }
        do {
            try await reloadSeason(session: session)
        } catch {
            guard !error.isCancellation else { return }
            loadError = loadError ?? LoadFailure("Couldn't Load the Episodes", error: error)
        }
    }

    private func seasonEpisodes(_ seasonId: String, session: ServerSession) async throws -> [JellyfinItem] {
        try await session.client.episodes(seriesId: series.id, seasonId: seasonId, userId: session.userId,
                                          fields: "Overview,PrimaryImageAspectRatio")
    }
}

/// An episode: its still with progress, number and title, length and overview, and whether it's
/// the one to watch next. A press plays it; a button beside it opens its page, which on Apple TV
/// focus reaches by moving right.
private struct EpisodeRow: View {
    let episode: JellyfinItem
    let isSelecting: Bool
    let isSelected: Bool
    let isNext: Bool
    let focus: FocusState<String?>.Binding
    let openPage: () -> Void
    /// Called once a change from the menu to other episodes besides this one has been made, and
    /// again after its Undo.
    let afterBatchChange: () async -> Void
    let action: () -> Void
    let onChange: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: 30) {
            row
            NavigationLink(value: episode) {
                Label("Details", systemImage: "info.circle")
            }
            .titleActionStyle()
            .accessibilityLabel("Details of \(episode.name)")
            .accessibilityIdentifier("episode.\(episode.indexNumber ?? 0).details")
        }
        #else
        HStack(alignment: .center, spacing: 8) {
            row
            if !isSelecting {
                NavigationLink(value: episode) {
                    Label("Details", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        // A whole fingertip's target, beside a row that plays the episode.
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Details")
                .accessibilityLabel("Details of \(episode.name)")
                .accessibilityIdentifier("episode.\(episode.indexNumber ?? 0).details")
            }
        }
        #endif
    }

    private var row: some View {
        Button(action: action) {
            // At the accessibility text sizes the still goes above the words, which need the width.
            AdaptiveStack(rowAlignment: .top, spacing: stillSpacing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? nil : .infinity)
                }
                Artwork(url: session?.client.imageURL(itemId: episode.id, tag: episode.primaryImageTag, maxWidth: 600),
                        aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
                    .frame(width: dynamicTypeSize.cardWidth(stillWidth))
                    .overlay { NotYetAvailableOverlay(item: episode) }
                    .overlay(alignment: .bottom) {
                        if let progress = episode.progress { ProgressBar(fraction: progress).padding(6) }
                    }
                    .overlay(alignment: .topTrailing) { WatchBadge(item: episode).padding(6) }
                    .liftsUnderFocus()
                VStack(alignment: .leading, spacing: 4) {
                    if isNext {
                        // In the text's color, marked by a dot of the accent: the accent's green
                        // as small text reads poorly.
                        Label {
                            Text(episode.resumeSeconds != nil ? "Continue" : "Up Next")
                        } icon: {
                            Image(systemName: "circle.fill")
                                .imageScale(.small)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                    }
                    HStack(spacing: 6) {
                        Text(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
                            .font(.headline)
                            .lineLimit(2)
                        #if !os(tvOS)
                        downloadBadge
                        #endif
                    }
                    if let runtime = episode.runtimeText {
                        Text(runtime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let overview = episode.overview {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(3))
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.artwork)
        .foregroundStyle(.primary)
        .focused(focus, equals: episode.id)
        // To VoiceOver a button that says what the row shows. As drawn it would read as selected
        // whenever the episode is watched: SwiftUI takes the watched badge's checkmark for a
        // selection.
        .accessibilityRepresentation {
            Button(spokenLabel, action: action)
        }
        .titleMenu(episode, onChange: onChange) {
            Button("Details", systemImage: "info.circle", action: openPage)
            MarkPreviousWatchedButton(episode: episode, afterChange: afterBatchChange)
        }
        .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
        .accessibilityHint(isSelecting ? "" : episode.isNotYetAvailable() ? "Not yet available. Opens the episode" : "Plays the episode")
        .accessibilityInputLabels([episode.name, "Episode \(episode.indexNumber ?? 0)"])
        .accessibilityIdentifier("episode.\(episode.indexNumber ?? 0)")
    }

    /// What the row shows, in the order it shows it: "Up Next, 3. What the Gulls Saw, Downloaded,
    /// Watched, 52 min", then the overview.
    private var spokenLabel: String {
        var parts: [String] = []
        if isNext { parts.append(episode.resumeSeconds != nil ? "Continue" : "Up Next") }
        parts.append(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
        #if !os(tvOS)
        if let download = spokenDownload { parts.append(download) }
        #endif
        if let notOut = NotYetAvailableOverlay.spoken(episode) { parts.append(notOut) }
        if episode.isPlayed { parts.append("Watched") }
        if let progress = episode.progress { parts.append(ProgressBar.spoken(progress)) }
        if let runtime = episode.spokenRuntime { parts.append(runtime) }
        if let overview = episode.overview, !overview.isEmpty { parts.append(overview) }
        return parts.joined(separator: ", ")
    }

    private var stillWidth: CGFloat {
        #if os(tvOS)
        380
        #elseif os(iOS)
        150
        #else
        220
        #endif
    }

    /// Apple TV's leaves room for the still to lift under focus without covering the words.
    private var stillSpacing: CGFloat {
        #if os(tvOS)
        44
        #else
        14
        #endif
    }

    #if !os(tvOS)
    private var spokenDownload: String? {
        let jobs = downloads.jobs(forItem: episode.id)
        if jobs.contains(where: { $0.status == .completed }) { return "Downloaded" }
        if jobs.contains(where: { $0.status == .failed }) { return "Download failed" }
        guard let job = jobs.first else { return nil }
        return "Downloading, \(DownloadRing.spokenProgress(of: job, downloads: downloads))"
    }

    @ViewBuilder private var downloadBadge: some View {
        let jobs = downloads.jobs(forItem: episode.id)
        if jobs.contains(where: { $0.status == .completed }) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                .accessibilityLabel("Downloaded")
        } else if jobs.contains(where: { $0.status == .failed }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .accessibilityLabel("Download failed")
        } else if let job = jobs.first {
            DownloadRing(job: job)
        }
    }
    #endif
}

/// Playing a show from its page or its long-press menu: its next episode, or with none next, its
/// first again; and its episodes shuffled, in an order Next, Previous and autoplay follow.
enum ShowPlayback {
    /// What a show's Play says: "Play Episode 3", "Resume Episode 2 · 31 min left", "Play S2, E1".
    /// `seasons` is how many the show has, specials aside.
    nonisolated static func playLabel(for episode: JellyfinItem, seasons: Int) -> String {
        let name = episodeName(episode, seasons: seasons) ?? episode.name
        guard episode.resumeSeconds != nil else { return "Play \(name)" }
        return ["Resume \(name)", episode.timeLeftText].compactMap(\.self).joined(separator: " · ")
    }

    /// `playLabel` as VoiceOver says it: "Resume Season 2, Episode 1, 31 minutes left".
    nonisolated static func spokenPlayLabel(for episode: JellyfinItem, seasons: Int) -> String {
        let name = spokenEpisodeName(episode, seasons: seasons) ?? episode.name
        guard episode.resumeSeconds != nil else { return "Play \(name)" }
        return ["Resume \(name)", episode.spokenTimeLeft].compactMap(\.self).joined(separator: ", ")
    }

    /// "Episode 3", "Episodes 3–4", or where the season doesn't go without saying, "S2, E1".
    nonisolated static func episodeName(_ episode: JellyfinItem, seasons: Int) -> String? {
        guard let number = episode.indexNumber else { return nil }
        guard seasonGoesWithoutSaying(episode, seasons: seasons) else { return episode.shortEpisodeCode }
        if let end = episode.indexNumberEnd, end > number { return "Episodes \(number)–\(end)" }
        return "Episode \(number)"
    }

    /// "Episode 3", "Episodes 3 to 4", "Season 2, Episode 1".
    nonisolated static func spokenEpisodeName(_ episode: JellyfinItem, seasons: Int) -> String? {
        guard let number = episode.indexNumber else { return nil }
        guard seasonGoesWithoutSaying(episode, seasons: seasons) else { return episode.spokenEpisodeCode }
        if let end = episode.indexNumberEnd, end > number { return "Episodes \(number) to \(end)" }
        return "Episode \(number)"
    }

    /// In a show's first season, or a show of one, an episode's number says which it is.
    nonisolated static func seasonGoesWithoutSaying(_ episode: JellyfinItem, seasons: Int) -> Bool {
        guard let season = episode.parentIndexNumber else { return true }
        return season == 1 || (seasons <= 1 && season != 0)
    }

    /// A show's menu's Play, which can't wait for the episode to name it: Watch Again once it's all
    /// watched, Play Next Episode while it's being watched, else Play.
    nonisolated static func menuTitle(for show: JellyfinItem) -> String {
        if show.isPlayed { return "Watch Again" }
        return (show.userData?.playedPercentage ?? 0) > 0 ? "Play Next Episode" : "Play"
    }

    /// The season a show's page opens on: the one asked for, as a link to an episode's season asks;
    /// else that of the episode next; else, for a show watched to its end, that of the episode
    /// watched last; else the first, specials aside.
    nonisolated static func initialSeason(in seasons: [JellyfinItem], requested: String?, next: JellyfinItem?,
                                          lastWatched: JellyfinItem?) -> String? {
        let ids = Set(seasons.map(\.id))
        let candidates = [requested, next?.seasonId, lastWatched?.seasonId].compactMap(\.self)
        if let found = candidates.first(where: ids.contains) { return found }
        if seasons.isEmpty { return requested }
        return seasons.first { ($0.indexNumber ?? 0) > 0 }?.id ?? seasons.first?.id
    }

    /// The show's first episode the player can play: of its first season, specials aside.
    /// `seasons` are the show's, when they're at hand.
    static func firstEpisode(of seriesId: String, seasons: [JellyfinItem]? = nil, session: ServerSession) async throws -> JellyfinItem? {
        let client = session.client
        let all = if let seasons, !seasons.isEmpty { seasons } else { try await client.seasons(seriesId: seriesId, userId: session.userId) }
        let first = all.first { ($0.indexNumber ?? 0) > 0 } ?? all.first
        let now = Date.now
        let episodes = try await client.episodes(seriesId: seriesId, seasonId: first?.id, userId: session.userId,
                                                 fields: JellyfinClient.cardFields, missing: false)
        if let found = episodes.first(where: { UpNext.canGoOn(to: $0, now: now) }) { return found }
        guard first != nil else { return nil }
        return try await client.episodes(seriesId: seriesId, seasonId: nil, userId: session.userId,
                                         fields: JellyfinClient.cardFields, missing: false)
            .first { UpNext.canGoOn(to: $0, now: now) }
    }

    /// Plays the show's next episode, or with none, its first from the start.
    static func playNext(of show: JellyfinItem, session: ServerSession, player: PlayerCoordinator, messages: AppMessages) async {
        do {
            if let next = try await session.client.upNext(seriesId: show.id, userId: session.userId) {
                player.play(.item(next))
            } else if let first = try await firstEpisode(of: show.id, session: session) {
                player.play(.item(first, fromBeginning: true))
            } else {
                messages.show("\(show.name) has no episodes to play yet.")
            }
        } catch {
            guard !error.isCancellation else { return }
            messages.show("Couldn't play \(show.name): \(error.localizedDescription)")
        }
    }

    /// Plays the show's episodes in a shuffled order of their own (`PlayOrder.shuffled`), a new
    /// one each time, from its first.
    static func shuffle(_ show: JellyfinItem, session: ServerSession, player: PlayerCoordinator, messages: AppMessages) async {
        do {
            let episodes = try await session.client.episodes(seriesId: show.id, seasonId: nil, userId: session.userId,
                                                             fields: JellyfinClient.cardFields, missing: false)
            let order = PlayOrder.shuffled(episodes, seed: .random(in: .min ... .max), now: .now)
            guard let firstId = order.ids.first, let first = episodes.first(where: { $0.id == firstId }) else {
                messages.show("\(show.name) has no episodes to play yet.")
                return
            }
            var request = PlaybackRequest.item(first)
            request.order = order
            player.play(request)
        } catch {
            guard !error.isCancellation else { return }
            messages.show("Couldn't shuffle \(show.name): \(error.localizedDescription)")
        }
    }
}
