import SwiftUI

/// A show's seasons as chips to pick one by, on a show's page and an episode's. A long press on a
/// chip offers what `menu` gives for its season. On Apple TV, focus coming into the chips lands on
/// the season chosen, wherever it comes from.
struct SeasonPicker<Menu: View>: View {
    let seasons: [JellyfinItem]
    @Binding var selection: String?
    @ViewBuilder var menu: (JellyfinItem) -> Menu
    /// Where the mark of the season chosen slides from chip to chip.
    @Namespace private var selectionMark
    #if os(tvOS)
    @FocusState private var focused: String?
    /// Bounds the chips' default focus, so it's theirs to take as focus comes in, not the page's.
    @Namespace private var chipsScope
    #endif

    var body: some View {
        if seasons.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(seasons) { season in
                        Button {
                            selection = season.id
                        } label: {
                            Text(season.name)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(SeasonChipStyle(isSelected: season.id == selection, mark: selectionMark))
                        #if os(tvOS)
                        .focused($focused, equals: season.id)
                        #endif
                        .contextMenu { menu(season) }
                        .accessibilityAddTraits(season.id == selection ? .isSelected : [])
                        .accessibilityIdentifier("season.\(season.name)")
                    }
                }
                .animation(.snappy, value: selection)
                .padding(.horizontal, Metrics.edge)
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .focusSection()
            .focusScope(chipsScope)
            .defaultFocus($focused, selection, priority: .userInitiated)
            #endif
        }
    }
}

extension SeasonPicker where Menu == EmptyView {
    init(seasons: [JellyfinItem], selection: Binding<String?>) {
        self.init(seasons: seasons, selection: selection) { _ in EmptyView() }
    }
}

/// A season's chip. On Apple TV it's glass, white glass being focus's alone, as across the system,
/// and the season chosen has its name in bold over a dot. Elsewhere the season chosen is filled.
/// Either way the mark slides to the chip chosen.
struct SeasonChipStyle: ButtonStyle {
    let isSelected: Bool
    let mark: Namespace.ID
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        configuration.label
            .font(.subheadline.weight(isSelected ? .bold : .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            .glassEffect(isFocused ? .focused : .regular, in: .capsule)
            .overlay(alignment: .bottom) {
                if isSelected {
                    // The page's text color, not the chip's, which goes dark on its glass under focus.
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 8, height: 8)
                        .matchedGeometryEffect(id: "selected", in: mark)
                        // Under the chip, clear of it as focus lifts it: an alignment guide here
                        // goes unheeded, and the dot sits on the chip's edge, under its glass.
                        .offset(y: 18)
                }
            }
            // With Reduce Motion, focus lifts it with its shadow alone.
            .scaleEffect(isFocused && !reduceMotion ? 1.12 : 1)
            .shadow(radius: isFocused ? 12 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .opacity(configuration.isPressed ? 0.7 : 1)
        #else
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? AnyShapeStyle(Self.chosenText) : AnyShapeStyle(.primary))
            .background {
                Capsule().fill(.quaternary)
                if isSelected {
                    Capsule().fill(.primary).matchedGeometryEffect(id: "selected", in: mark)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
        #endif
    }

    #if !os(tvOS)
    /// The chosen chip's text, on its `.primary` fill: the page's color, but black on Vision Pro,
    /// whose pages can be the window's glass, and whose background style is light glass too.
    private static var chosenText: Color {
        #if os(visionOS)
        .black
        #else
        .pageBackground
        #endif
    }
    #endif
}

/// The rest of a show on an episode's page: its seasons, and one season's episodes as a row of
/// stills, starting on the episode's season with the episode marked and in view. Picking another
/// episode shows its page in this one's place, and picking the one shown goes back up to it.
///
/// The episode shown is the page's: a change to it there, such as marking it watched, shows on
/// its card, and one made from a card's menu goes back to the page.
///
/// While the server is out of reach it keeps what it shows, and loads once the server answers.
struct SeasonBrowser: View {
    /// The episode the page shows.
    let episode: JellyfinItem
    /// How many times the page has reloaded; each reload loads the season's episodes again.
    var reloads = 0
    let select: (JellyfinItem) -> Void
    /// Told of an episode a card's menu changed, such as marked watched.
    var onChange: (JellyfinItem) -> Void = { _ in }

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var seasons: [JellyfinItem] = []
    @State private var seasonId: String?
    /// The episodes in the row, of `episodesSeasonId`: while another season's load, the last one's.
    @State private var episodes: [JellyfinItem]?
    @State private var episodesSeasonId: String?
    /// The episodes of each season loaded so far, which show at once as their season is picked
    /// again, while they load again.
    @State private var loaded: [String: [JellyfinItem]] = [:]
    @State private var problem: LoadFailure?
    @State private var position = ScrollPosition(idType: String.self)
    #if os(tvOS)
    @FocusState private var focused: String?
    /// The episode focus was on last, which it goes back to as it comes into the row.
    @State private var lastFocused: String?
    /// Bounds the row's default focus, so it's the row's to take when focus comes in, and not the
    /// page's as it opens.
    @Namespace private var rowScope
    #endif

    var body: some View {
        if let seriesId = episode.seriesId {
            VStack(alignment: .leading, spacing: 10) {
                Text("Episodes")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Metrics.edge)
                SeasonPicker(seasons: seasons, selection: $seasonId)
                row
            }
            .task(id: seriesId) { await loadSeasons(seriesId: seriesId) }
            .task(id: seasonId) { await loadEpisodes(seriesId: seriesId) }
            // An episode of another season picked elsewhere on the page, such as with Play Next.
            .onChange(of: episode.seasonId) { _, new in
                if let new, seasons.contains(where: { $0.id == new }) { seasonId = new }
            }
            .onChange(of: episode) { _, shown in
                update(shown.id) { $0.userData = shown.userData }
            }
            .onChange(of: reloads) { Task { await reload(seriesId: seriesId) } }
            // The server answering again, after it was out of reach.
            .onChange(of: reachability.isOutOfReach) { _, isOutOfReach in
                guard !isOutOfReach else { return }
                Task {
                    if seasons.isEmpty { await loadSeasons(seriesId: seriesId) }
                    await loadEpisodes(seriesId: seriesId)
                }
            }
            .onChange(of: player.endedPlayback) {
                if let episodes { self.episodes = player.endedPlayback.applied(to: episodes) }
                loaded = loaded.mapValues { player.endedPlayback.applied(to: $0) }
            }
        }
    }

    /// Another season's episodes are on their way, and the last one's stand dimmed in their place.
    private var isSwitching: Bool { episodes != nil && episodesSeasonId != seasonId }

    @ViewBuilder private var row: some View {
        if let problem, !reachability.isOutOfReach, episodes == nil || isSwitching, let seriesId = episode.seriesId {
            LoadFailureNotice(problem) {
                Task {
                    if seasons.isEmpty { await loadSeasons(seriesId: seriesId) }
                    await loadEpisodes(seriesId: seriesId)
                }
            }
            .padding(.horizontal, Metrics.edge)
        } else if let episodes, !episodes.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                    ForEach(episodes) { other in
                        Button {
                            select(other)
                        } label: {
                            EpisodeCard(episode: other, isShown: other.id == episode.id)
                        }
                        .buttonStyle(.artwork)
                        .frame(width: dynamicTypeSize.cardWidth(Metrics.landscapeWidth))
                        #if os(tvOS)
                        .focused($focused, equals: other.id)
                        #endif
                        .titleMenu(other, onChange: { updated in
                            update(updated.id) { $0 = updated }
                            onChange(updated)
                        }) {
                            MarkPreviousWatchedButton(episode: other) { await reloadAfterBatchChange() }
                        }
                        .accessibilityHint(other.id == episode.id ? "Goes back up to it" : "Shows this episode")
                        .accessibilityIdentifier("seasonBrowser.episode.\(other.indexNumber ?? 0)")
                    }
                }
                .scrollTargetLayout()
                #if os(tvOS)
                .padding(.vertical, 30)
                #endif
            }
            // Margins rather than padding, so an episode scrolled to lines up with the page's edge.
            .contentMargins(.horizontal, Metrics.edge, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition($position, anchor: .leading)
            .scrollClipDisabled()
            .opacity(isSwitching ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.2), value: isSwitching)
            #if os(tvOS)
            .focusSection()
            .focusScope(rowScope)
            .defaultFocus($focused, entryFocus(in: episodes), priority: .userInitiated)
            .onChange(of: focused) { _, new in if let new { lastFocused = new } }
            #endif
            .onAppear { reveal(in: episodes) }
            .onChange(of: episode.id) { reveal(in: episodes) }
            .onChange(of: episodesSeasonId) { reveal(in: episodes) }
        } else if episodes == nil {
            if reachability.isOutOfReach {
                EpisodesOfflineNote()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    /// Scrolls the episode shown into view, with the one before it beside it for where it sits,
    /// or for another season, to its first.
    private func reveal(in episodes: [JellyfinItem]) {
        if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
            position.scrollTo(id: episodes[max(0, index - 1)].id, anchor: .leading)
        } else if let first = episodes.first {
            position.scrollTo(id: first.id, anchor: .leading)
        }
    }

    #if os(tvOS)
    /// Where focus enters the row: the episode it was on last in this season, else the episode shown,
    /// else the first.
    private func entryFocus(in episodes: [JellyfinItem]) -> String? {
        [lastFocused, episode.id].compactMap(\.self).first { id in episodes.contains { $0.id == id } }
            ?? episodes.first?.id
    }
    #endif

    /// Changes the episode `id` in the row and in the seasons loaded.
    private func update(_ id: String, _ change: (inout JellyfinItem) -> Void) {
        func apply(_ list: inout [JellyfinItem]) {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            var changed = list[index]
            change(&changed)
            if changed != list[index] { list[index] = changed }
        }
        if var episodes {
            apply(&episodes)
            self.episodes = episodes
        }
        for key in loaded.keys { apply(&loaded[key, default: []]) }
    }

    private func loadSeasons(seriesId: String) async {
        guard let session, !reachability.isOutOfReach else { return }
        do {
            let found = try await session.client.seasons(seriesId: seriesId, userId: session.userId)
            seasons = found
            if seasonId == nil {
                seasonId = episode.seasonId.flatMap { id in found.first { $0.id == id }?.id } ?? found.first?.id
            }
        } catch {
            guard !error.isCancellation else { return }
            problem = LoadFailure("Couldn't Load the Seasons", error: error)
        }
    }

    /// The season picked's episodes: at once if they loaded before, then as they are now.
    private func loadEpisodes(seriesId: String) async {
        guard let session, let seasonId else { return }
        if episodesSeasonId != seasonId, let known = loaded[seasonId] { show(known, of: seasonId) }
        guard !reachability.isOutOfReach else { return }
        do {
            let found = try await session.client.episodes(seriesId: seriesId, seasonId: seasonId, userId: session.userId,
                                                          fields: "Overview,PrimaryImageAspectRatio")
            guard seasonId == self.seasonId else { return }
            show(found, of: seasonId)
            problem = nil
        } catch {
            guard !error.isCancellation else { return }
            problem = LoadFailure("Couldn't Load the Episodes", error: error)
        }
    }

    /// The season's episodes as they are now, with the others' to load again as they're picked:
    /// what changed may have changed them too, as marking a show watched does.
    private func reload(seriesId: String) async {
        guard let session, let seasonId, !reachability.isOutOfReach else { return }
        loaded = loaded.filter { $0.key == seasonId }
        guard let found = try? await session.client.episodes(seriesId: seriesId, seasonId: seasonId, userId: session.userId,
                                                             fields: "Overview,PrimaryImageAspectRatio"),
              seasonId == self.seasonId else { return }
        show(found, of: seasonId)
    }

    /// After a change to several episodes from a card's menu, and after its Undo: the season's
    /// episodes as they are now, and the episode shown's state for the page.
    private func reloadAfterBatchChange() async {
        guard let seriesId = episode.seriesId else { return }
        await reload(seriesId: seriesId)
        if let shown = episodes?.first(where: { $0.id == episode.id }) { onChange(shown) }
    }

    /// Puts a season's episodes in the row, fading from the last season's.
    private func show(_ found: [JellyfinItem], of seasonId: String) {
        loaded[seasonId] = found
        guard found != episodes || episodesSeasonId != seasonId else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            episodes = found
            episodesSeasonId = seasonId
        }
    }
}

/// An episode in a row of a season's: its still with progress and watch state, its number and
/// name, and its length. The one whose page is open says so.
private struct EpisodeCard: View {
    let episode: JellyfinItem
    let isShown: Bool
    @State private var artworkHeight: CGFloat = 0
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: session?.client.imageURL(itemId: episode.id, tag: episode.primaryImageTag, maxWidth: 600),
                    aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
                .overlay { NotYetAvailableOverlay(item: episode) }
                .overlay(alignment: .bottom) {
                    if let progress = episode.progress { ProgressBar(fraction: progress).padding(8) }
                }
                .overlay(alignment: .topTrailing) { WatchBadge(item: episode).padding(6) }
                .overlay(alignment: .topLeading) {
                    if isShown {
                        Text("Viewing")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: .capsule)
                            .padding(6)
                    }
                }
                .overlay {
                    if isShown { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary, lineWidth: 2) }
                }
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
                    .font(.subheadline.weight(isShown ? .bold : .medium))
                    .lineLimit(dynamicTypeSize.lineLimit(1))
                if let runtime = episode.runtimeText {
                    Text(runtime).font(.caption).foregroundStyle(.secondary)
                }
            }
            .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(episode.name)
        .accessibilityValue([episode.spokenEpisodeCode, isShown ? "viewing" : nil, NotYetAvailableOverlay.spoken(episode),
                             WatchBadge.spokenState(of: episode),
                             episode.progress.map(ProgressBar.spoken)].compactMap(\.self).joined(separator: ", "))
    }
}
