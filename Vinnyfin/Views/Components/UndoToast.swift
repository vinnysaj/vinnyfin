import SwiftUI

extension View {
    /// The toast offering to take back the change just made (`AppMessages.undoOffer`), at the foot
    /// of the screen, above the tab bar. On Apple TV, where it can't take focus from the page
    /// under it, Play/Pause takes the change back while it shows.
    func undoToasts() -> some View {
        modifier(UndoToasts())
    }
}

private struct UndoToasts: ViewModifier {
    @Environment(AppMessages.self) private var messages
    /// The tab is the one on screen. The others keep their views, and would each show the toast,
    /// and say it to VoiceOver, too.
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        let offer = isOnScreen ? messages.undoOffer : nil
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .overlay(alignment: .bottom) {
                if let offer {
                    UndoToast(offer: offer) { messages.undo(offer.id) } expire: { messages.expireUndo(offer.id) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: offer?.id)
            #if os(tvOS)
            .onPlayPauseCommand(perform: offer.map { offer in { messages.undo(offer.id) } })
            #endif
    }
}

/// Says what changed, and offers to take it back for a few seconds; on Apple TV, with the
/// Play/Pause button.
private struct UndoToast: View {
    let offer: UndoOffer
    let undo: () -> Void
    /// The time to take it back is over.
    let expire: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// How long the toast stays; long enough to reach Undo with VoiceOver too.
    private var duration: Duration { .seconds(voiceOverEnabled ? 15 : 6) }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(offer.title).font(.subheadline.weight(.semibold))
                Text(offer.detail).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            #if os(tvOS)
            Label("Undo", systemImage: "playpause.fill")
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel("Play/Pause to undo")
            #else
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.platformGlass)
                .accessibilityIdentifier("toast.undo")
            #endif
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .padding(.horizontal, Metrics.edge)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .task(id: offer.id) {
            AccessibilityNotification.Announcement(offer.announcement).post()
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            expire()
        }
    }
}
