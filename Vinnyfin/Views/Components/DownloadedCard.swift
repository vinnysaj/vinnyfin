#if !os(tvOS)
import SwiftUI

/// A downloaded title as a card that plays it: the picture saved with the download, which shows
/// offline, how far it was watched, and its name. An episode leads with its show's.
struct DownloadedCard: View {
    let item: JellyfinItem
    @State private var artworkHeight: CGFloat = 0
    @Environment(DownloadManager.self) private var downloads
    @Environment(WatchHistory.self) private var history
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            player.play(PlaybackRequest(source: .item(id: item.id, mediaSourceId: nil), title: item.titleWithYear))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: artworkURL, aspectRatio: 16.0 / 9.0, placeholder: item.isEpisode ? "tv" : "film")
                    .overlay(alignment: .bottom) {
                        if let progress { ProgressBar(fraction: progress).padding(Metrics.overlayInset) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.titleName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(dynamicTypeSize.lineLimit(1))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(1))
                }
                .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
            }
            .contentShape(.interaction, .rect)
            #if os(macOS)
            .help([item.titleName, detail].joined(separator: ", "))
            #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.titleName)
            .accessibilityValue([item.isEpisode ? spokenEpisode : item.premiereYearText, progress.map(ProgressBar.spoken), "downloaded"]
                .compactMap(\.self).joined(separator: ", "))
        }
        .buttonStyle(.artwork)
        .accessibilityHint("Plays it")
        .accessibilityIdentifier("downloaded.card.\(item.name)")
    }

    /// An episode's own still, a movie's backdrop; else whichever of the two was saved.
    private var artworkURL: URL? {
        let still = downloads.artworkURL(itemId: item.id, kind: .primary)
        let backdrop = downloads.artworkURL(itemId: item.id, kind: .backdrop)
        return item.isEpisode ? still ?? backdrop : backdrop ?? still
    }

    /// "S1, E2 · Dead Reckoning" for an episode, the year for a movie.
    private var detail: String {
        guard item.isEpisode else { return item.premiereYearText ?? "" }
        return [item.shortEpisodeCode, item.name].compactMap(\.self).joined(separator: " · ")
    }

    private var spokenEpisode: String {
        [item.spokenEpisodeCode, item.name].compactMap(\.self).joined(separator: ", ")
    }

    /// How far it was watched: on this device, or as the server said when it was last heard from.
    private var progress: Double? {
        if let entry = history.entry(for: item.id) {
            guard let duration = entry.duration, duration > 0, entry.position > 0, !entry.played else { return nil }
            return entry.position / duration
        }
        return item.progress
    }
}
#endif
