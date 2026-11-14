import SwiftUI

/// How the player shows the show's episodes, and which of them is in view.
nonisolated enum EpisodesLayout {
    enum Form: Equatable {
        /// A list, in a sheet.
        case sheet
        /// A row on glass, above the controls' bottom bar.
        case drawer
        /// A row of smaller cards on glass, over the controls' bottom bar.
        case rail
    }

    /// A list in a sheet on a phone held upright, which has room below the picture; a row over
    /// the bottom bar where the band between the controls' bars is short, as on a phone on its
    /// side; else a row above the bottom bar.
    static func form(isCompactWidth: Bool, isCompactHeight: Bool, isShortBand: Bool) -> Form {
        if isCompactWidth, !isCompactHeight { return .sheet }
        return isShortBand ? .rail : .drawer
    }

    /// The sheet's height on a screen `screen` big: the part below a picture of `videoSize`'s
    /// shape, 16:9 until it's known, fitted across it; never less than `minimumSheet`, room for a
    /// few episodes.
    static func sheetHeight(screen: CGSize, videoSize: CGSize?) -> CGFloat {
        let aspect = videoSize.flatMap { $0.width > 0 && $0.height > 0 ? $0.height / $0.width : nil } ?? 9.0 / 16.0
        let picture = min(screen.height, screen.width * aspect)
        return max(minimumSheet, ((screen.height - picture) / 2).rounded(.down))
    }

    static let minimumSheet: CGFloat = 320

    /// The episode to bring into view among a season's `episodes`: the one playing when it's
    /// among them, else, for another season, its first.
    static func inView(among episodes: [JellyfinItem], playing: JellyfinItem) -> String? {
        episodes.contains { $0.id == playing.id } ? playing.id : episodes.first?.id
    }
}

#if os(iOS) || os(macOS)
/// The show's episodes in the player, from the Episodes button: on a phone held upright, a list in
/// a sheet over the empty half of the screen below the picture; on a wider screen, a drawer of
/// them along the bottom, above the timeline, or over it where the screen is short. Previous and
/// Next play the episodes either side of this one, and any episode picked plays in its place.
struct EpisodesPanel: View {
    typealias Form = EpisodesLayout.Form

    let model: PlayerModel
    let playing: JellyfinItem
    let form: Form
    /// Called on every use, so the controls stay up meanwhile.
    var onInteraction: () -> Void = {}
    let onClose: () -> Void

    var body: some View {
        EpisodeStrip(model: model, playing: playing, axis: form == .sheet ? .vertical : .horizontal, isCompact: form == .rail,
                     onInteraction: onInteraction, onPlay: onClose) {
            buttons
        }
        .padding(.top, form == .sheet ? 20 : 14)
        .padding(.bottom, form == .sheet ? 0 : 14)
        .modifier(DrawerGlass(isDrawer: form != .sheet))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("player.episodesPanel")
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                step { await model.playPreviousEpisode() }
            } label: {
                Label("Previous Episode", systemImage: "backward.end.fill")
            }
            .help("Previous Episode")
            .accessibilityIdentifier("episodes.previous")
            Button {
                step { await model.playNextEpisode() }
            } label: {
                Label("Next Episode", systemImage: "forward.end.fill")
            }
            .disabled(model.nextEpisode == nil)
            .accessibilityHint(model.nextEpisode?.name ?? "")
            .help("Next Episode")
            .accessibilityIdentifier("episodes.next")
            if form != .sheet {
                Button("Close", systemImage: "xmark", action: onClose)
                    .help("Close")
            }
        }
        .labelStyle(.iconOnly)
        .font(.body)
        .buttonStyle(.platformGlass)
        .buttonBorderShape(.circle)
    }

    /// Plays another episode, and gets out of its way.
    private func step(_ play: @escaping () async -> Void) {
        onInteraction()
        onClose()
        Task { await play() }
    }
}

/// The drawer's and the rail's glass; the sheet has its own.
private struct DrawerGlass: ViewModifier {
    let isDrawer: Bool

    func body(content: Content) -> some View {
        if isDrawer {
            content
                .frame(maxWidth: 1100)
                .platformGlass(in: .rect(cornerRadius: 28))
        } else {
            content
        }
    }
}
#endif
