import SwiftUI

/// The A–Z strip down the leading side of a library. Tap a letter, or slide up and down the
/// strip, to jump; on Apple TV, move left from the grid to it and press one. It's on the leading
/// side, clear of the scroll indicator on the trailing one, which takes touches and clicks there
/// while it shows: the letters under it would scrub the grid instead of jumping.
///
/// On a page pushed onto a navigation stack the strip is where the swipe back starts, so a slide
/// takes it only once it's gone a little way, mostly up or down; one sideways goes back.
struct AlphabetIndex: View {
    /// Letters that have a section; the rest are dimmed and jump to the next one.
    let available: Set<String>
    /// On Apple TV, the letter of the title focus was last on in the grid, where focus comes in.
    var current: String?
    let onSelect: (String) -> Void

    /// The width of the strip of letters at the grid's side.
    static var width: CGFloat {
        #if os(tvOS)
        60
        #else
        20
        #endif
    }

    #if !os(tvOS)
    /// The width that takes touches and clicks: the strip and the gap after it, out to the grid,
    /// as the letters alone make a target too narrow to hit reliably.
    static let touchWidth: CGFloat = 28
    #endif
    #if os(macOS) || os(visionOS)
    /// How far a drag goes before it scrubs, short of which it's a click or tap on a letter.
    private static let slop: CGFloat = 8
    #endif

    @State private var active: String?
    #if os(tvOS)
    @FocusState private var focusedLetter: String?
    /// Bounds the strip's default focus, so it's the strip's to take when focus comes in.
    @Namespace private var focusScope
    /// A row's height, 27 of which fit the TV's height below the toolbar.
    private static let rowHeight: CGFloat = 25
    #else
    /// Where the letters are laid out, on screen.
    @State private var layoutTop: CGFloat = 0
    /// Where they were as the finger came down, kept until it lifts.
    @State private var heldTop: CGFloat?
    /// Takes the large letter a tap shows away again.
    @State private var dismissal: Task<Void, Never>?
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private let letters = LibraryIndex.alphabet

    var body: some View {
        #if os(tvOS)
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    onSelect(letter)
                } label: {
                    Text(letter)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: Self.rowHeight)
                        .foregroundStyle(available.contains(letter) ? .primary : dimmed)
                }
                .buttonStyle(IndexLetterStyle())
                .focused($focusedLetter, equals: letter)
                .accessibilityIdentifier("index.\(letter)")
            }
        }
        // The letter with focus, large beside the strip, where it reads from across the room.
        .overlay(alignment: .topLeading) {
            if let focusedLetter, let row = letters.firstIndex(of: focusedLetter) {
                Text(focusedLetter)
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .frame(width: 130, height: 130)
                    .platformGlass(in: .rect(cornerRadius: 28))
                    .offset(x: Self.width + 24, y: (CGFloat(row) + 0.5) * Self.rowHeight - 65)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.15), value: focusedLetter == nil)
        .frame(width: Self.width)
        // Down to the bottom of the screen, so focus moving left from any card in the grid's
        // first column comes here, not just from those beside the letters.
        .frame(maxHeight: .infinity, alignment: .top)
        .focusSection()
        .focusScope(focusScope)
        // Rather than whichever letter is level with the card focus leaves.
        .defaultFocus($focusedLetter, current, priority: .userInitiated)
        #else
        GeometryReader { geometry in
            let rowHeight = max(9, min(17, (geometry.size.height - 16) / CGFloat(letters.count)))
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: rowHeight - 4, weight: .semibold, design: .rounded))
                        .frame(width: Self.width, height: rowHeight)
                        .foregroundStyle(available.contains(letter) ? AnyShapeStyle(.tint) : AnyShapeStyle(dimmed))
                        .accessibilityElement()
                        .accessibilityLabel(letter == "#" ? "Numbers and symbols" : letter)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { select(letter) }
                        // Too small to grow with the text, its letter shows large when held.
                        .accessibilityShowsLargeContentViewer()
                        .accessibilityIdentifier("index.\(letter)")
                }
            }
            .padding(.vertical, 8)
            .background {
                if active != nil { Capsule().fill(.thinMaterial) }
            }
            .frame(width: Self.width)
            .frame(width: Self.touchWidth, alignment: .leading)
            .contentShape(.rect)
            #if os(iOS)
            .gesture(VerticalSlide { scrub(to: $0, rowHeight: rowHeight) } onEnd: { endScrub() })
            #else
            .gesture(
                DragGesture(minimumDistance: Self.slop)
                    .onChanged { scrub(to: $0.location.y, rowHeight: rowHeight) }
                    .onEnded { _ in endScrub() }
            )
            #endif
            .onTapGesture { location in
                let letter = letter(at: location.y, rowHeight: rowHeight)
                active = letter
                onSelect(letter)
                // The large letter shows for a moment.
                dismissal?.cancel()
                dismissal = Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { active = nil }
                }
            }
            .overlay(alignment: .leading) {
                if let active {
                    Text(active)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .frame(width: 72, height: 72)
                        .platformGlass(in: .rect(cornerRadius: 18))
                        .offset(x: Self.width + 4)
                        .motionTransition(.scale.combined(with: .opacity), reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                }
            }
            // Held still under the finger. A jump from the top of the list collapses the large
            // title, and back to the top expands it, which moves the strip, centered between
            // the bars, by half the title's height: the finger would be on another letter.
            .offset(y: heldTop.map { $0 - layoutTop } ?? 0)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { layoutTop = $0 }
            .frame(maxHeight: .infinity, alignment: .center)
            .sensoryFeedback(.selection, trigger: active)
        }
        .frame(width: Self.touchWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Index")
        #endif
    }

    /// A letter without titles: faint, or with Increase Contrast, readable still.
    private var dimmed: HierarchicalShapeStyle {
        contrast == .increased ? .secondary : .tertiary
    }

    #if !os(tvOS)
    /// The letter at `y` down the strip, whose letters start below its padding.
    private func letter(at y: CGFloat, rowHeight: CGFloat) -> String {
        letters[min(letters.count - 1, max(0, Int((y - 8) / rowHeight)))]
    }

    /// Jumps to the letter under a slide `y` down the strip.
    private func scrub(to y: CGFloat, rowHeight: CGFloat) {
        dismissal?.cancel()
        if heldTop == nil { heldTop = layoutTop }
        select(letter(at: y, rowHeight: rowHeight))
    }

    private func endScrub() {
        withAnimation(.easeOut(duration: 0.25)) {
            active = nil
            heldTop = nil
        }
    }
    #endif

    private func select(_ letter: String) {
        guard letter != active else { return }
        active = letter
        onSelect(letter)
    }
}

#if os(tvOS)
private struct IndexLetterStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .foregroundStyle(isFocused ? .black : .primary)
            .scaleEffect(isFocused && !reduceMotion ? 1.25 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif

#if os(iOS)
/// A slide up or down, reporting how far down it is. One that sets off sideways never begins,
/// which leaves it to the navigation stack's swipe back: a SwiftUI drag would take any slide
/// once it began, and the strip would block going back from its edge.
private struct VerticalSlide: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChange(context.converter.localLocation.y)
        case .ended, .cancelled, .failed: onEnd()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let moved = pan.translation(in: pan.view)
            return abs(moved.y) >= abs(moved.x)
        }
    }
}
#endif
