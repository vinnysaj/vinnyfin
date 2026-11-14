import SwiftUI

/// A show's seasons as chips to pick one by, on a show's page and an episode's. A long press on a
/// chip offers what `menu` gives for its season.
struct SeasonPicker<Menu: View>: View {
    let seasons: [JellyfinItem]
    @Binding var selection: String?
    @ViewBuilder var menu: (JellyfinItem) -> Menu

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
                        .buttonStyle(SeasonChipStyle(isSelected: season.id == selection))
                        .contextMenu { menu(season) }
                        .accessibilityAddTraits(season.id == selection ? .isSelected : [])
                        .accessibilityIdentifier("season.\(season.name)")
                    }
                }
                .padding(.horizontal, Metrics.edge)
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }
}

extension SeasonPicker where Menu == EmptyView {
    init(seasons: [JellyfinItem], selection: Binding<String?>) {
        self.init(seasons: seasons, selection: selection) { _ in EmptyView() }
    }
}

struct SeasonChipStyle: ButtonStyle {
    let isSelected: Bool
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Chosen, the page's color on the text's: the background style is light glass on
            // Vision Pro, as light as the chip.
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.pageBackground) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary), in: .capsule)
            #if os(tvOS)
            // With Reduce Motion, focus lifts it with its shadow alone.
            .scaleEffect(isFocused && !reduceMotion ? 1.12 : 1)
            .shadow(radius: isFocused ? 12 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            #endif
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The rest of a show on an episode's page: its seasons, and one season's episodes as a row of
/// stills, starting on the episode's season with the episode marked and in view. Picking another
/// episode shows its page in this one's place.
struct SeasonBrowser: View {
    /// The episode the page shows.
    let episode: JellyfinItem
    let select: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var seasons: [JellyfinItem] = []
    @State private var seasonId: String?
    @State private var episodes: [JellyfinItem]?
    @State private var problem: String?
    @State private var position = ScrollPosition(idType: String.self)
    #if os(tvOS)
    @FocusState private var focused: String?
    /// The episode focus was on last, which it goes back to as it comes into the row.
    @State private var lastFocused: String?
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
            .onChange(of: player.endedPlayback) {
                if let episodes { self.episodes = player.endedPlayback.applied(to: episodes) }
            }
        }
    }

    @ViewBuilder private var row: some View {
        if let episodes, !episodes.isEmpty {
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
                        .titleMenu(other) { updated in
                            if let index = self.episodes?.firstIndex(where: { $0.id == updated.id }) { self.episodes?[index] = updated }
                        }
                        .accessibilityHint(other.id == episode.id ? "" : "Shows this episode")
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
            #if os(tvOS)
            .focusSection()
            .defaultFocus($focused, lastFocused ?? episode.id, priority: .userInitiated)
            .onChange(of: focused) { _, new in if let new { lastFocused = new } }
            #endif
            .onAppear { reveal(in: episodes) }
            .onChange(of: episode.id) { reveal(in: episodes) }
        } else if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.edge)
        } else if episodes == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }

    /// Scrolls the episode shown into view, with the one before it beside it for where it sits.
    private func reveal(in episodes: [JellyfinItem]) {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        position.scrollTo(id: episodes[max(0, index - 1)].id, anchor: .leading)
    }

    private func loadSeasons(seriesId: String) async {
        guard let session else { return }
        do {
            let found = try await session.client.seasons(seriesId: seriesId, userId: session.userId)
            seasons = found
            if seasonId == nil {
                seasonId = episode.seasonId.flatMap { id in found.first { $0.id == id }?.id } ?? found.first?.id
            }
        } catch {
            guard !error.isCancellation else { return }
            problem = "Couldn't load the seasons: \(error.localizedDescription)"
        }
    }

    private func loadEpisodes(seriesId: String) async {
        guard let session, let seasonId else { return }
        if episodes?.first?.seasonId != seasonId { episodes = nil }
        do {
            let found = try await session.client.episodes(seriesId: seriesId, seasonId: seasonId, userId: session.userId,
                                                          fields: "Overview,PrimaryImageAspectRatio")
            guard seasonId == self.seasonId else { return }
            episodes = found
            problem = nil
        } catch {
            guard !error.isCancellation else { return }
            problem = "Couldn't load the episodes: \(error.localizedDescription)"
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
        .accessibilityValue([episode.spokenEpisodeCode, isShown ? "viewing" : nil, WatchBadge.spokenState(of: episode),
                             episode.progress.map(ProgressBar.spoken)].compactMap(\.self).joined(separator: ", "))
    }
}
