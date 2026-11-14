import SwiftUI

/// The A–Z strip down the leading side of a library. Tap a letter, or slide along the strip, to
/// jump; on Apple TV, move left from the grid to it and press one. It's on the leading side,
/// clear of the scroll indicator on the trailing one, which takes touches and clicks there
/// while it shows: the letters under it would scrub the grid instead of jumping.
struct AlphabetIndex: View {
    /// Letters that have a section; the rest are dimmed and jump to the next one.
    let available: Set<String>
    /// On Apple TV, the letter of the title focus was last on in the grid, where focus comes in.
    var current: String?
    let onSelect: (String) -> Void

    /// The width of the strip at the grid's side. Off Apple TV all of it takes touches, wider
    /// than the letters, which alone make a target too narrow to hit reliably.
    static var width: CGFloat {
        #if os(tvOS)
        60
        #else
        44
        #endif
    }

    @State private var active: String?
    #if os(tvOS)
    @FocusState private var focusedLetter: String?
    /// Bounds the strip's default focus, so it's the strip's to take when focus comes in.
    @Namespace private var focusScope
    #else
    /// Where the letters are laid out, on screen.
    @State private var layoutTop: CGFloat = 0
    /// Where they were as the finger came down, kept until it lifts.
    @State private var heldTop: CGFloat?
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
                    // 27 rows fit the TV's height below the toolbar.
                    Text(letter)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 25)
                        .foregroundStyle(available.contains(letter) ? .primary : dimmed)
                }
                .buttonStyle(IndexLetterStyle())
                .focused($focusedLetter, equals: letter)
                .accessibilityIdentifier("index.\(letter)")
            }
        }
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
                        .frame(width: 22, height: rowHeight)
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
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if heldTop == nil { heldTop = layoutTop }
                        let position = Int((value.location.y - 8) / rowHeight)
                        select(letters[min(letters.count - 1, max(0, position))])
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            active = nil
                            heldTop = nil
                        }
                    }
            )
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
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Index")
        #endif
    }

    /// A letter without titles: faint, or with Increase Contrast, readable still.
    private var dimmed: HierarchicalShapeStyle {
        contrast == .increased ? .secondary : .tertiary
    }

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
