import SwiftUI

/// Side by side, or one above the other at the accessibility text sizes, where side by side the
/// pieces would crowd each other into truncation.
struct AdaptiveStack<Content: View>: View {
    /// How the pieces line up one above the other.
    var alignment = HorizontalAlignment.leading
    /// How they line up side by side.
    var rowAlignment = VerticalAlignment.center
    var spacing: CGFloat?
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: alignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: rowAlignment, spacing: spacing))
        layout { content }
    }
}

extension DynamicTypeSize {
    /// A card's width at this text size: wider at the accessibility sizes, so its title has room
    /// for the larger words, but no wider than fits a phone's screen.
    func cardWidth(_ width: CGFloat) -> CGFloat {
        let scale: CGFloat = switch self {
        case .accessibility1, .accessibility2: 1.5
        case .accessibility3, .accessibility4, .accessibility5: 2
        default: 1
        }
        return min(width * scale, max(width, 340))
    }

    /// Lines for text that's `lines` long at the default size and smaller: one more at the larger
    /// standard sizes, and two more at the accessibility sizes, where a line holds a word or two.
    func lineLimit(_ lines: Int) -> Int {
        if isAccessibilitySize { lines + 2 } else if self > .large { lines + 1 } else { lines }
    }
}

extension View {
    /// A title's long-press menu, with the same commands among its accessibility actions, where
    /// VoiceOver, Voice Control and Switch Control reach them without a long press. Nil, as for a
    /// title still loading, has none.
    func titleMenu(_ item: JellyfinItem?, onChange: @escaping (JellyfinItem) -> Void = { _ in }) -> some View {
        titleMenu(item, onChange: onChange) { EmptyView() }
    }

    /// A title's long-press menu with `more` commands after its own, all of them among its
    /// accessibility actions too.
    func titleMenu<More: View>(_ item: JellyfinItem?, onChange: @escaping (JellyfinItem) -> Void = { _ in },
                               @ViewBuilder more: () -> More) -> some View {
        let more = more()
        return contextMenu {
            if let item {
                ItemContextMenu(item: item, onChange: onChange)
                more
            }
        }
        .accessibilityActions {
            if let item {
                ItemContextMenu(item: item, onChange: onChange)
                more
            }
        }
    }

    /// A transition that moves or scales, or with Reduce Motion on, only fades.
    func motionTransition(_ transition: AnyTransition, reduceMotion: Bool) -> some View {
        self.transition(reduceMotion ? .opacity : transition)
    }
}

/// Times as VoiceOver should say them: "1 hour, 4 minutes, 9 seconds" rather than "1:04:09",
/// which it reads as a time of day.
enum SpokenTime {
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unknown" }
        return Duration.seconds(Int(max(0, seconds))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// "4 minutes, 9 seconds of 1 hour, 30 minutes".
    static func position(_ time: Double, of duration: Double) -> String {
        "\(text(time)) of \(text(duration))"
    }
}

/// Says something to VoiceOver, without moving its cursor: a change it would otherwise miss, as
/// results arriving or a button appearing over the picture. Nothing without VoiceOver.
@MainActor
func announce(_ message: String) {
    AccessibilityNotification.Announcement(message).post()
}
