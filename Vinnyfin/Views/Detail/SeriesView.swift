import AppIntents
import SwiftUI

/// A show: play the next episode, download a season or all of it, keep it downloaded, and its
/// episodes one season at a time. Select turns the episodes into checkboxes for downloading
/// several at once.
struct SeriesView: View {
    let series: JellyfinItem
    var initialSeasonId: String?

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.openTitle) private var openTitle
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    @Environment(\.scenePhase) private var scenePhase
    #if !os(tvOS)
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadManager.self) private var downloads
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
    @State private var similar: [JellyfinItem] = []
    @State private var loadError: LoadFailure?
    /// The server answered that it doesn't have the show, which asking again won't change.
    @State private var isGone = false
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var batch: Batch?
    /// On screen, rather than under a page pushed over it or in another tab.
    @State private var isOnScreen = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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

    /// Play stands in place, unable to play, until it's known whether there's an episode next, so
    /// the buttons don't move as it comes; and on Apple TV, so focus starts on it rather than on
    /// a switch that would mark the whole show. With nothing next it goes once the episodes are
    /// in, for focus to go to the first of them.
    private var showsPlay: Bool {
        guard !isGone else { return false }
        return nextUp != nil || !nextUpLoaded || (episodes == nil && loadError == nil)
    }

    var body: some View {
        EdgeToEdgeScrollView(underTopBars: true) {
            VStack(alignment: .leading, spacing: 24) {
                DetailHero(item: shown) { actions }
                VStack(alignment: .leading, spacing: 24) {
                    if isGone {
                        TitleGoneNotice()
                            .padding(.horizontal, Metrics.edge)
                    } else if let loadError {
                        LoadFailureNotice(loadError) { Task { await retry() } }
                            .padding(.horizontal, Metrics.edge)
                    }
                    OverviewText(item: shown).padding(.horizontal, Metrics.edge)
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
                    }
                    if !similar.isEmpty { MoreLikeThisShelf(title: shown, titles: $similar) }
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
        .onChange(of: player.endedPlayback) {
            similar = player.endedPlayback.applied(to: similar)
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

    /// Play, then the rest: in one row, or where that doesn't fit, Play on a row above the rest.
    private var actions: some View {
        TitleActionsLayout {
            if showsPlay { playButton }
            if !isGone {
                Group { secondaryButtons }
                    .layoutValue(key: SecondaryTitleAction.self, value: true)
            }
        }
        .focusCaptionRoom()
    }

    /// The next episode's Play, or until it's known, Play standing in for it, which plays nothing.
    /// It's the same button throughout, so focus stays on it as the episode comes.
    private var playButton: some View {
        Button {
            if let nextUp { player.play(.item(nextUp)) }
        } label: {
            Label(nextUp.map(playLabel) ?? "Play", systemImage: "play.fill").frame(minWidth: 120)
        }
        .buttonStyle(.platformGlassProminent)
        .controlSize(.large)
        #if os(tvOS)
        // Still focusable, so focus can start on it.
        .opacity(nextUp == nil ? 0.5 : 1)
        #else
        .disabled(nextUp == nil)
        #endif
        // Its title on one line: the row's other buttons would otherwise take width it needs. At
        // the accessibility text sizes, where one line can be wider than the screen, it wraps.
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        .accessibilityLabel(nextUp.map(spokenPlayLabel) ?? "Play")
        .accessibilityInputLabels(nextUp.map { [$0.resumeSeconds != nil ? "Resume" : "Play", playLabel(for: $0)] } ?? ["Play"])
        .accessibilityIdentifier("series.play")
        #if os(tvOS)
        .focused($playFocused)
        #endif
    }

    @ViewBuilder private var secondaryButtons: some View {
        #if !os(tvOS)
        smartDownloadMenu
        #endif
        // Marking the show marks every episode, which the list then shows.
        WatchedButton(item: shown) { detail = $0 } afterChange: { await reloadWatchState() }
        FavoriteButton(item: shown) { detail = $0 }
        if let nextUp {
            PlayElsewhereButton(subject: .title(nextUp, mediaSourceId: nil))
                .help(PlayElsewhereSheet.title)
        }
    }

    /// "Play S1, E3", or "Resume S1, E2 · 31 min left".
    private func playLabel(for episode: JellyfinItem) -> String {
        let code = episode.shortEpisodeCode ?? episode.name
        guard episode.resumeSeconds != nil else { return "Play \(code)" }
        return ["Resume \(code)", episode.timeLeftText].compactMap(\.self).joined(separator: " · ")
    }

    /// "Resume Season 1, Episode 2, 31 minutes left", which VoiceOver would otherwise spell out.
    private func spokenPlayLabel(for episode: JellyfinItem) -> String {
        let code = episode.spokenEpisodeCode ?? episode.name
        guard episode.resumeSeconds != nil else { return "Play \(code)" }
        return ["Resume \(code)", episode.spokenTimeLeft].compactMap(\.self).joined(separator: ", ")
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
            let symbol = rule == nil ? "arrow.down.circle" : "sparkles.rectangle.stack.fill"
            // Just the symbol in a row too narrow for the title, as on iPhone Duo's outer display.
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: symbol)
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
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
                    batch = Batch(episodes: (currentEpisodes ?? []).filter { selection.contains($0.id) })
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("series.download")
            }
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
            openPage: { openTitle?(episode) }
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

    private func load() async {
        guard let session else { return }
        loadError = nil
        do {
            async let detail = session.client.item(id: series.id, userId: session.userId)
            async let seasons = session.client.seasons(seriesId: series.id, userId: session.userId)
            async let nextUp = session.client.upNext(seriesId: series.id, userId: session.userId)
            self.detail = try await detail
            let found = try await seasons
            self.seasons = found
            let next = try await nextUp
            self.nextUp = next
            nextUpLoaded = true
            isGone = false
            if seasonId == nil {
                seasonId = initialSeasonId ?? next?.seasonId ?? found.first { ($0.indexNumber ?? 0) > 0 }?.id ?? found.first?.id
            }
        } catch JellyfinError.http(let status, _) where status == 404 {
            isGone = true
            detail = nil
            return
        } catch {
            guard !error.isCancellation else { return }
            loadError = LoadFailure("Couldn't Load the Show", error: error)
        }
        do {
            similar = try await session.client.similar(to: series.id, userId: session.userId, limit: MoreLikeThisShelf.length)
        } catch {
            guard !error.isCancellation else { return }
            similar = []
            loadError = loadError ?? LoadFailure("Couldn't Load Shows Like This", error: error)
        }
    }

    /// The season picked's episodes: at once if they loaded before, then as they are now. Until
    /// they come, the last season's stay listed, dimmed, so the page keeps its place.
    private func loadEpisodes() async {
        guard let session, let seasonId else { return }
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
        guard let session else { return }
        do {
            async let detail = session.client.item(id: series.id, userId: session.userId)
            async let nextUp = session.client.upNext(seriesId: series.id, userId: session.userId)
            async let seasons = session.client.seasons(seriesId: series.id, userId: session.userId)
            try await reloadSeason(session: session)
            self.detail = try await detail
            self.nextUp = try await nextUp
            nextUpLoaded = true
            self.seasons = try await seasons
        } catch {
            guard !error.isCancellation else { return }
            loadError = LoadFailure("Couldn't Load the Show", error: error)
        }
    }

    /// Marks a whole season watched or not, then shows what that changed.
    private func setPlayed(_ played: Bool, season: JellyfinItem) async {
        guard let session else { return }
        await WatchActions.setPlayed(played, on: season, session: session, messages: messages) { updated in
            if let index = seasons.firstIndex(where: { $0.id == updated.id }) { seasons[index] = updated }
        }
        await reloadWatchState()
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

    /// Pulled down: all of the page again, the season's episodes as they are now too.
    private func refresh() async {
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
/// the one to watch next. Off Apple TV, a button beside it opens its page; on Apple TV its menu does.
private struct EpisodeRow: View {
    let episode: JellyfinItem
    let isSelecting: Bool
    let isSelected: Bool
    let isNext: Bool
    let focus: FocusState<String?>.Binding
    let openPage: () -> Void
    let action: () -> Void
    let onChange: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        #if os(tvOS)
        row
        #else
        HStack(alignment: .center, spacing: 8) {
            row
            if !isSelecting {
                Button(action: openPage) {
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
        .titleMenu(episode, onChange: onChange) {
            Button("Details", systemImage: "info.circle", action: openPage)
        }
        .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
        .accessibilityHint(isSelecting ? "" : episode.isNotYetAvailable() ? "Not yet available. Opens the episode" : "Plays the episode")
        .accessibilityInputLabels([episode.name, "Episode \(episode.indexNumber ?? 0)"])
        .accessibilityIdentifier("episode.\(episode.indexNumber ?? 0)")
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
