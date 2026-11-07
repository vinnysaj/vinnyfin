import SwiftUI

/// The A–Z strip down the side of a library. Tap a letter, or slide along the strip, to jump.
struct AlphabetIndex: View {
    /// Letters that have a section; the rest are dimmed and jump to the next one.
    let available: Set<String>
    let onSelect: (String) -> Void

    @State private var active: String?
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
                .accessibilityIdentifier("index.\(letter)")
            }
        }
        .focusSection()
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
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let position = Int((value.location.y - 8) / rowHeight)
                        select(letters[min(letters.count - 1, max(0, position))])
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.25)) { active = nil }
                    }
            )
            .overlay(alignment: .trailing) {
                if let active {
                    Text(active)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .frame(width: 72, height: 72)
                        .platformGlass(in: .rect(cornerRadius: 18))
                        .offset(x: -48)
                        .motionTransition(.scale.combined(with: .opacity), reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .sensoryFeedback(.selection, trigger: active)
        }
        .frame(width: 26)
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
