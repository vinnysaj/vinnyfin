import SwiftUI

// Apple TV runs its focus-driven scrolling through a scroll view's target behavior: the scroll
// view's position comes as the original target, and the focus engine's choice as the target.

/// Where Apple TV scrolls a row of same-width cards as focus moves along it. The focus engine
/// asks for just enough to show the focused card and the one past it; this goes on from there,
/// in the direction focus moved, to where a card starts at the row's leading margin. The cards
/// stay in the columns of the row's title and of the rows above and below, and the focused card
/// is never left cut off at the screen's edge, as it is snapped to the nearest card instead.
struct CardRowScrollBehavior: ScrollTargetBehavior {
    /// A card's width and the space after it.
    let stride: CGFloat
    /// Told where each scroll is headed.
    var onScroll: (CGFloat) -> Void = { _ in }

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = Self.offset(from: context.originalTarget.rect.minX, toward: target.rect.minX, stride: stride,
                                           limit: context.contentSize.width - context.containerSize.width)
        onScroll(target.rect.minX)
    }

    /// Where a row at `current` scrolls when focus asks for `proposed`: the first card start at
    /// or past it in the direction of the move, within the row's `limit`.
    nonisolated static func offset(from current: CGFloat, toward proposed: CGFloat, stride: CGFloat, limit: CGFloat) -> CGFloat {
        guard proposed != current, stride > 0 else { return proposed }
        // A hair either way, so a proposal a rounding error past a card start stays on it.
        let cards = proposed / stride
        let aligned = (proposed > current ? (cards - 0.001).rounded(.up) : (cards + 0.001).rounded(.down)) * stride
        return min(max(0, aligned), max(0, limit))
    }
}

/// Keeps a scroll view that scrolls up and down from moving sideways. Apple TV's focus engine
/// and a scroll to a card both shift it sideways, toward a card near the screen's edge, even
/// though nothing is off to the side, and the whole grid then sits off center until focus moves.
nonisolated struct VerticalScrollBehavior: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = 0
    }
}

/// Where a row of a page of rows sits while it has focus on Apple TV.
nonisolated enum RowHold: Equatable {
    /// Its top a set distance down from the page's: the rows.
    case top
    /// Scrolled up only until all of it shows, under what fits of what's above it: the first
    /// row under a banner, which stays partly in view.
    case whole

    /// The page's content offset with a row in `frame` focused, its top held `top` down, on a
    /// page `viewport` high with content `content` high.
    func offset(for frame: CGRect, top: CGFloat, viewport: CGFloat, content: CGFloat) -> CGFloat {
        let wanted = switch self {
        case .top: frame.minY - top
        case .whole: frame.maxY - viewport
        }
        return min(max(0, wanted), max(0, content - viewport))
    }
}

#if os(tvOS)
import UIKit

/// The rows of a page that scrolls up and down through rows of cards, and where each is, so
/// Apple TV can hold the row with focus at the same height as focus moves up and down, as the
/// TV app does, rather than the focus engine's least scroll, which leaves it at the bottom of
/// the screen moving down and at the top moving up.
///
/// The page's content takes its coordinate space with `rowPageContent(_:)`, the rows say where
/// they are in it with `pageRow(_:in:holding:)`, and the page scrolls by them with `rowPage(_:)`.
final class RowPageLayout {
    struct Row {
        var frame = CGRect.null
        var hold: RowHold
        /// Made by the page's lazy stack, which lets go of rows far off screen; one it let go
        /// of has a frame from before, which what's above it may have moved since.
        var isMade = true
    }

    /// The coordinate space of the page's content, for the rows' frames.
    fileprivate let space = UUID()
    fileprivate var rows: [AnyHashable: Row] = [:]
    fileprivate var memories: [AnyHashable: RowFocusMemory] = [:]
    /// The top of the page's content on screen, which moves as the page scrolls.
    fileprivate var contentTop: CGFloat = 0

    fileprivate func memory(for key: AnyHashable) -> RowFocusMemory {
        if let memory = memories[key] { return memory }
        let memory = RowFocusMemory()
        memories[key] = memory
        return memory
    }

    /// The row whose frame takes in `y`, in the content's coordinates.
    fileprivate func row(at y: CGFloat) -> Row? {
        rows.values.first { $0.isMade && $0.frame.minY <= y && y < $0.frame.maxY }
    }

    /// What has focus, on screen. The focus engine has moved focus by the time it asks a scroll
    /// view where to scroll, before SwiftUI's focus state hears of it.
    fileprivate static func focusedFrame() -> CGRect? {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard let window = scene?.keyWindow, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem,
              let space = item.parentFocusEnvironment?.focusItemContainer?.coordinateSpace else { return nil }
        return space.convert(item.frame, to: window.coordinateSpace)
    }
}

/// Where focus and the scroll were in a row of cards, for focus to go back to coming into the
/// row from above or below, as in the TV app. A page of rows keeps it rather than the row: the
/// page's lazy stack lets go of rows far off screen, and of their state with them, so a row
/// keeping it itself would come back scrolled to its start with focus wherever it lands.
final class RowFocusMemory {
    /// What had focus, as the row identifies it.
    var focus: AnyHashable?
    /// How far the row was scrolled.
    var offset: CGFloat = 0
}

extension EnvironmentValues {
    /// The memory a page of rows keeps for the row this is in.
    @Entry var rowFocusMemory: RowFocusMemory?
}

/// Scrolls a page of rows to hold the row that takes focus where its `RowHold` says, in place
/// of the focus engine's least scroll. Focus outside the rows scrolls as the engine has it.
struct RowPageScrollBehavior: ScrollTargetBehavior {
    /// How far down the focused row's top is held: below the TV's overscan margin, with the next
    /// row's title and most of its cards in view under it.
    static let top = Metrics.edge

    let layout: RowPageLayout

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard target.rect.minY != context.originalTarget.rect.minY, let focused = RowPageLayout.focusedFrame(),
              let row = layout.row(at: focused.midY - layout.contentTop) else { return }
        target.rect.origin.y = row.hold.offset(for: row.frame, top: Self.top,
                                               viewport: context.containerSize.height, content: context.contentSize.height)
    }
}

extension View {
    /// A page of rows that holds the focused one in place.
    func rowPage(_ layout: RowPageLayout) -> some View {
        scrollTargetBehavior(RowPageScrollBehavior(layout: layout))
    }

    /// The content of a `rowPage`, all of what scrolls.
    func rowPageContent(_ layout: RowPageLayout) -> some View {
        coordinateSpace(.named(layout.space))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { layout.contentTop = $0 }
    }

    /// One of a `rowPage`'s rows, and where it sits while it has focus. A row of cards in it
    /// keeps where focus was in it with the page (see `RowFocusMemory`).
    func pageRow(_ id: some Hashable, in layout: RowPageLayout, holding hold: RowHold = .top) -> some View {
        let key = AnyHashable(id)
        // A row made again keeps the frame it had: the geometry it reports only when it changes.
        return environment(\.rowFocusMemory, layout.memory(for: key))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(layout.space)) } action: { frame in
            layout.rows[key, default: .init(hold: hold)].frame = frame
        }
        .onChange(of: hold, initial: true) { layout.rows[key, default: .init(hold: hold)].hold = hold }
        .onAppear { layout.rows[key, default: .init(hold: hold)].isMade = true }
        .onDisappear { layout.rows[key]?.isMade = false }
    }
}
#endif
