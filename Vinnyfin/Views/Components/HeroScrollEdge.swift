import SwiftUI

extension View {
    /// Keeps the bars over a page with a hero out of the hero's way: while the hero's words are
    /// below the bars, the artwork runs clean to the top of the screen, without the bars'
    /// background, their scroll edge effect or the page's title, which the hero already shows.
    /// Once the words scroll up under the bars, all three fade back in, so what scrolls under the
    /// bars after the hero is blurred and the title says where the page is.
    ///
    /// Put it on an `EdgeToEdgeScrollView(underTopBars: true)` whose content starts with a
    /// `DetailHero` (or Home's banner), in place of hiding the bars' background there. The hero
    /// tells it where its words are; a page without one keeps its bars as they are. The page keeps
    /// its `screenTitle`, which also names it in the back button's history. Apple TV, whose bars
    /// sit over the content anyway, is left alone; the Mac keeps its window's title.
    func heroScrollEdge() -> some View {
        modifier(HeroScrollEdge())
    }

    /// Marks a hero's words, the top of its title down to its buttons, for `heroScrollEdge`.
    func heroWords() -> some View {
        modifier(HeroWords())
    }
}

/// Whether a hero's words are below the bars over the page. A hero scrolled out of a lazy stack,
/// or gone from the page, says nothing, and the bars come back.
private struct HeroWordsBelowBarsKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct HeroScrollEdge: ViewModifier {
    @State private var clear = false

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .onPreferenceChange(HeroWordsBelowBarsKey.self) { below in
                withAnimation(.smooth) { clear = below }
            }
            .toolbarBackgroundVisibility(clear ? .hidden : .automatic, for: .automatic)
            #if !os(visionOS)
            .scrollEdgeEffectHidden(clear, for: .top)
            #endif
            #if os(iOS) || os(visionOS)
            .toolbar(removing: clear ? .title : nil)
            #endif
        #endif
    }
}

private struct HeroWords: ViewModifier {
    @Environment(\.topBarsHeight) private var topBarsHeight
    /// Where a hero first shows, at the top of its page, its words are at its foot.
    @State private var belowBars = true

    func body(content: Content) -> some View {
        let barsHeight = topBarsHeight
        content
            .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY >= barsHeight } action: { belowBars = $0 }
            .preference(key: HeroWordsBelowBarsKey.self, value: belowBars)
    }
}
