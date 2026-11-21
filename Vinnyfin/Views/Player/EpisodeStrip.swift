import SwiftUI

/// The show's episodes in the player, a season at a time, starting from the one playing, which
/// is marked and in view: in a row below the fold of an iPhone Duo standing half open, under
/// Vision Pro's window, in the Episodes panel's drawer and on Apple TV's Episodes tab, and as a
/// list in the panel's sheet on a phone held upright. Picking one plays it in place. Offline, the
/// show's downloads.
struct EpisodeStrip<Accessory: View>: View {
    let model: PlayerModel
    let playing: JellyfinItem
    var axis: Axis = .horizontal
    /// Smaller cards, for a short screen.
    var isCompact = false
    /// Nothing moves on its own: below the fold, which stays still while the picture plays above.
    var isStill = false
    /// Called as it's scrolled or used, so controls that fade stay up meanwhile.
    var onInteraction: () -> Void = {}
    /// Called as an episode is picked to play.
    var onPlay: () -> Void = {}
    /// At the end of the season's row: the panel's own buttons.
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.session) private var session
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var seasons: [JellyfinItem] = []
    @State private var seasonId: String?
    @State private var episodes: [JellyfinItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Self.headerSpacing) {
            header
            ScrollViewReader { proxy in
                Group {
                    if axis == .horizontal { row } else { list }
                }
                .onScrollPhaseChange { _, phase in
                    if phase.isScrolling { onInteraction() }
                }
                .onChange(of: episodes) { scrollIntoView(proxy) }
                .onChange(of: playing.id) { withAnimation { scrollIntoView(proxy) } }
            }
        }
        .task(id: playing.seriesId) { await loadSeasons() }
        .task(id: seasonId) { await loadEpisodes() }
        // The next episode can be the next season's first.
        .onChange(of: playing.seasonId) { _, season in seasonId = season }
    }

    private func scrollIntoView(_ proxy: ScrollViewProxy) {
        guard let id = EpisodesLayout.inView(among: episodes, playing: playing) else { return }
        proxy.scrollTo(id, anchor: axis == .horizontal ? .leading : .top)
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                ForEach(episodes) { episode in
                    button(episode) { card(episode) }
                }
            }
            .scrollTargetLayout()
            #if os(tvOS)
            // Room for the card with focus to lift.
            .padding(.vertical, 24)
            #endif
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Self.inset, for: .scrollContent)
        // As tall as its cards: a scroll view takes all the height it's offered.
        .fixedSize(horizontal: false, vertical: true)
        #if os(tvOS)
        .scrollClipDisabled()
        .focusSection()
        #endif
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(episodes) { episode in
                    button(episode) { listRow(episode) }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func button(_ episode: JellyfinItem, @ViewBuilder label: () -> some View) -> some View {
        Button {
            onInteraction()
            onPlay()
            Task { await model.play(episode) }
        } label: {
            label()
        }
        .buttonStyle(.artwork)
        .id(episode.id)
        .accessibilityIdentifier("episodes.episode.\(episode.indexNumber ?? 0)")
    }

    private var header: some View {
        HStack(spacing: 12) {
            if seasons.count > 1 {
                Menu {
                    Picker("Season", selection: $seasonId) {
                        ForEach(seasons) { Text($0.name).tag(Optional($0.id)) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(seasonName)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                }
                #if os(macOS)
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                #elseif os(tvOS)
                .buttonStyle(.platformGlass)
                #endif
                .accessibilityIdentifier("episodes.season")
            } else {
                Text(seasonName)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .font(.headline)
        .padding(.horizontal, Self.inset)
    }

    private var seasonName: String {
        seasons.first { $0.id == seasonId }?.name ?? playing.seasonName ?? "Episodes"
    }

    private func card(_ episode: JellyfinItem) -> some View {
        let isPlaying = episode.id == playing.id
        return VStack(alignment: .leading, spacing: 6) {
            still(episode, isPlaying: isPlaying)
                .liftsUnderFocus()
            Text(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.lineLimit(1))
            // Compact, the strip keeps clear of the transport above it.
            if !isCompact, let runtime = episode.runtimeText {
                Text(runtime).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: dynamicTypeSize.cardWidth(isCompact ? Self.compactCardWidth : Self.cardWidth))
        .modifier(EpisodeAccessibility(episode: episode, isPlaying: isPlaying))
    }

    private func listRow(_ episode: JellyfinItem) -> some View {
        let isPlaying = episode.id == playing.id
        return HStack(alignment: .top, spacing: 12) {
            still(episode, isPlaying: isPlaying)
                .frame(width: 132)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.lineLimit(2))
                if let runtime = episode.runtimeText {
                    Text(runtime).font(.caption).foregroundStyle(.secondary)
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(2))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 6)
        .background(isPlaying ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .modifier(EpisodeAccessibility(episode: episode, isPlaying: isPlaying))
    }

    /// The episode's still, with how far it was watched or that it was, and the one playing marked.
    private func still(_ episode: JellyfinItem, isPlaying: Bool) -> some View {
        Artwork(url: session?.client.imageURL(itemId: episode.id, tag: episode.primaryImageTag, maxWidth: Self.imagePixels),
                aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
            .overlay(alignment: .bottom) {
                if let progress = episode.progress, !isPlaying { ProgressBar(fraction: progress).padding(6) }
            }
            .overlay(alignment: .topTrailing) {
                if !isPlaying { WatchBadge(item: episode).padding(6) }
            }
            .overlay {
                if isPlaying {
                    RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(.white, lineWidth: 2)
                    Image(systemName: "waveform")
                        .font(.title2.weight(.semibold))
                        // Still with Reduce Motion: the stroke around it marks it.
                        .symbolEffect(.variableColor.iterative, isActive: model.isPlaying && !reduceMotion && !isStill)
                        .shadow(radius: 4)
                }
            }
    }

    private func loadSeasons() async {
        seasonId = playing.seasonId
        guard let session, let seriesId = playing.seriesId else { return }
        do {
            seasons = try await session.client.seasons(seriesId: seriesId, userId: session.userId)
        } catch {
            // Offline: the downloads are listed together, without seasons.
            seasons = []
        }
    }

    private func loadEpisodes() async {
        guard let seriesId = playing.seriesId else { return }
        if let session {
            do {
                episodes = try await session.client.episodes(seriesId: seriesId, seasonId: seasonId, userId: session.userId,
                                                             fields: JellyfinClient.listFields)
                return
            } catch is CancellationError {
                return
            } catch {
                // Falls through to what's downloaded.
            }
        }
        #if !os(tvOS)
        episodes = downloads.downloadedEpisodes(seriesId: seriesId)
        #endif
    }

    private static var cardWidth: CGFloat {
        #if os(tvOS)
        360
        #else
        168
        #endif
    }

    private static var compactCardWidth: CGFloat { 136 }

    private static var cardSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        12
        #endif
    }

    private static var headerSpacing: CGFloat {
        #if os(tvOS)
        0
        #else
        10
        #endif
    }

    private static var imagePixels: Int {
        #if os(tvOS)
        720
        #else
        400
        #endif
    }

    /// From the strip's sides to the first card: the player's inset, which on Apple TV is the
    /// screen's own.
    private static var inset: CGFloat {
        #if os(tvOS)
        0
        #else
        Metrics.playerInset
        #endif
    }
}

extension EpisodeStrip where Accessory == EmptyView {
    init(model: PlayerModel, playing: JellyfinItem, axis: Axis = .horizontal, isCompact: Bool = false, isStill: Bool = false,
         onInteraction: @escaping () -> Void = {}, onPlay: @escaping () -> Void = {}) {
        self.init(model: model, playing: playing, axis: axis, isCompact: isCompact, isStill: isStill,
                  onInteraction: onInteraction, onPlay: onPlay) { EmptyView() }
    }
}

/// An episode in the strip as VoiceOver reads it: its name, with its number, whether it's the one
/// playing, and how far it was watched.
private struct EpisodeAccessibility: ViewModifier {
    let episode: JellyfinItem
    let isPlaying: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(episode.name)
            .accessibilityValue([episode.spokenEpisodeCode, isPlaying ? "playing" : nil, WatchBadge.spokenState(of: episode),
                                 episode.progress.map(ProgressBar.spoken)].compactMap(\.self).joined(separator: ", "))
            .accessibilityAddTraits(isPlaying ? .isSelected : [])
            .accessibilityInputLabels([episode.name, "Episode \(episode.indexNumber ?? 0)"])
    }
}
