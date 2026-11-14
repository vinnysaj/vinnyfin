import SwiftUI

/// Toolbar spots by role. The Mac's window toolbar has no navigation bar, so there they map to
/// its leading and trailing ends.
extension ToolbarItemPlacement {
    static var barLeading: Self {
        #if os(macOS) || os(tvOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    static var barTrailing: Self {
        #if os(macOS) || os(tvOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }

    /// The screen's main action, kept out of the overflow menu when the bar is narrow, as on
    /// iPhone Duo's outer display.
    static var barPinnedTrailing: Self {
        #if os(macOS) || os(tvOS)
        .primaryAction
        #else
        .topBarPinnedTrailing
        #endif
    }
}

extension View {
    /// The screen's title in the navigation bar, except on Apple TV. There the bar stays over the
    /// content as it scrolls, so a title in it sits on whatever scrolls under; the sidebar names
    /// each tab's first screen, and other screens head their content with their title. Hiding
    /// the bar instead hangs the app when a screen that hides it is pushed.
    func screenTitle(_ title: some StringProtocol) -> some View {
        #if os(tvOS)
        self
        #else
        navigationTitle(title)
        #endif
    }

    /// A small title in the bar. The Mac's window toolbar and Apple TV have only the one style.
    func inlineNavigationTitle() -> some View {
        #if os(macOS) || os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Where finished downloads show up, in each platform's words.
enum FinishedFiles {
    #if os(macOS)
    static let browser = "Finder"
    static let place = "Downloads"
    static let hint = "Downloads are saved in Downloads › vinnyfin, where other apps can open them too."

    /// Finder opens a folder's file URL.
    static func browserURL(for folder: URL) -> URL { folder }
    #else
    static let browser = "Files"
    static let place = "Files"
    static var hint: String {
        "Downloads are saved in the Files app under On My \(Device.name) › vinnyfin, where other apps can open them too."
    }

    /// Opens the Files app at a folder of this app's Documents.
    static func browserURL(for folder: URL) -> URL {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = folder.path
        return components.url ?? folder
    }
    #endif
}

/// Liquid Glass where the system has it. Vision Pro draws all its controls on its own glass
/// material instead, which its standard bordered styles already use.
#if os(visionOS)
typealias PlatformGlassButtonStyle = BorderedButtonStyle
#else
typealias PlatformGlassButtonStyle = GlassButtonStyle
#endif

/// A screen's main action, filled with the accent color: on Liquid Glass, or on Vision Pro its
/// own glass. Its title is near-black, which reads on the sage green at about 8 to 1, and on dark
/// mode's lighter green at more, where white reads at only 2 to 2.6. With Increase Contrast the
/// fill is the accent's deeper high-contrast green instead, with a white title, at 5.9 to 1. Apple
/// TV's prominent buttons turn white under focus, with a dark title, by themselves.
struct PlatformGlassProminentButtonStyle: PrimitiveButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast

    /// The accent green's own high-contrast variant in light mode, which white reads on.
    private static let increasedContrastFill = Color(red: 0.20658, green: 0.43823, blue: 0.27906)
    /// The title on the accent green: black but for a little light, as the system's dark labels are.
    private static let title = Color(white: 0.08)

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(configuration)
            #if os(visionOS)
            .buttonStyle(.borderedProminent)
            #else
            .buttonStyle(.glassProminent)
            #endif
        #if os(tvOS)
        button
        #else
        if contrast == .increased {
            button
                .tint(Self.increasedContrastFill)
                .foregroundStyle(.white)
        } else {
            // Vision Pro's prominent style fills with its own gray, like the plain bordered style
            // beside it, unless it's given the accent itself.
            button
                .tint(.accentColor)
                .foregroundStyle(Self.title)
        }
        #endif
    }
}

extension PrimitiveButtonStyle where Self == PlatformGlassButtonStyle {
    static var platformGlass: Self {
        #if os(visionOS)
        .bordered
        #else
        .glass
        #endif
    }
}

extension PrimitiveButtonStyle where Self == PlatformGlassProminentButtonStyle {
    static var platformGlassProminent: Self { PlatformGlassProminentButtonStyle() }
}

extension View {
    func platformGlass(in shape: some InsettableShape) -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: shape)
        #else
        glassEffect(.regular, in: shape)
        #endif
    }
}

extension View {
    /// Artwork in a card that lifts under focus, the pointer or the eyes. Apple TV lifts it under
    /// focus, with the system's sheen, sway and glass rim: the card's button style lifts the first
    /// picture in its label by itself, but not one clipped to rounded corners, as `Artwork` is,
    /// and without this focus barely shows on it. iPad's pointer and Vision Pro's gaze lift the
    /// artwork's rounded shape rather than the whole card with its caption, and on the Mac it
    /// grows a little under the pointer.
    func liftsUnderFocus() -> some View {
        #if os(tvOS)
        hoverEffect(.highlight)
        #elseif os(macOS)
        modifier(PointerLift())
        #else
        contentShape(.hoverEffect, .rect(cornerRadius: Metrics.cardRadius))
            .hoverEffect(.lift)
        #endif
    }
}

#if os(macOS)
/// Grows a card's artwork a little while the pointer is over it.
private struct PointerLift: ViewModifier {
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1)
            .brightness(isHovered ? 0.04 : 0)
            .animation(.snappy(duration: 0.2), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
#endif

/// The title and details under a card's artwork. On Apple TV they're dimmed but for the card
/// with focus, so it stands out beside its row, and move down out of the way of its artwork as
/// focus lifts it.
struct CardCaptionStyle: ViewModifier {
    /// The artwork's height. The lift grows it by about 15 percent, half of that below.
    var artworkHeight: CGFloat = 0
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .foregroundStyle(isFocused ? HierarchicalShapeStyle.primary : .secondary)
            .offset(y: isFocused ? artworkHeight * 0.075 : 0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
        #else
        content
        #endif
    }
}

extension View {
    /// Tells `height` the view's height, on Apple TV, where a card's caption moves by it.
    func measuresCardArtwork(_ height: Binding<CGFloat>) -> some View {
        #if os(tvOS)
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.wrappedValue = $0 }
        #else
        self
        #endif
    }
}

/// For artwork cards: Apple TV lifts them under focus; elsewhere they stay untinted, with the
/// title in the text color rather than the accent, and give a little under a finger or a click,
/// on iPhone and iPad with a light tap felt as they do.
#if os(tvOS)
typealias ArtworkButtonStyle = BorderlessButtonStyle

extension PrimitiveButtonStyle where Self == ArtworkButtonStyle {
    static var artwork: Self { .borderless }
}
#else
struct ArtworkButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // With Reduce Motion it dims instead of moving.
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
            #if os(iOS)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: configuration.isPressed) { _, pressed in pressed }
            #endif
    }
}

extension ButtonStyle where Self == ArtworkButtonStyle {
    static var artwork: Self { ArtworkButtonStyle() }
}
#endif

extension View {
    #if os(tvOS)
    /// A search field that's always on screen.
    func alwaysSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        searchable(text: text, prompt: prompt)
    }
    #else
    /// A search field that's always on screen. On iPhone, a search tab's field placed
    /// automatically never appears: neither in the navigation bar nor in the tab bar. `isActive`
    /// is whether it has the cursor, and setting it puts the cursor there.
    func alwaysSearchable(text: Binding<String>, isActive: Binding<Bool>, prompt: LocalizedStringKey) -> some View {
        #if os(iOS)
        searchable(text: text, isPresented: isActive, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        searchable(text: text, isPresented: isActive, prompt: prompt)
        #endif
    }
    #endif
}

/// A vertical scroll view whose artwork and rows run the whole width: past Apple TV's overscan
/// margin, and elsewhere under the bars at the sides, like iPad's sidebar and iPhone Duo's
/// vertical bar, and up under the bars over the top when `underTopBars`. At the sides the view and
/// its content keep to the safe area: what's laid over the view, and the content's text and
/// controls, `Metrics.edge` in, stay clear of the bars, while artwork runs under them with
/// `ignoresSafeArea(edges: .horizontal)` and rows of cards scroll under them on their own. Over the
/// top, content keeps clear of the bars with `topBarsHeight`. Apple TV's overscan margin isn't a
/// bar: there the content runs to the screen's edges, and it and what's laid over the view keep to
/// `Metrics.edge`.
struct EdgeToEdgeScrollView<Content: View>: View {
    /// Runs up under the bars over the top, as a page does whose artwork starts at the screen's top.
    var underTopBars = false
    @ViewBuilder let content: Content
    #if !os(tvOS)
    /// How far the bars over the top reach, the only inset measured. Artwork can run up under
    /// those bars only when the scroll view gives that part of the safe area up, and then nothing
    /// inside it knows where they end. At the sides the safe area does the work instead: measuring
    /// a side's inset and padding content by it hangs iPhone Duo's outer display, whose vertical
    /// bar moves by a fraction of a point with the content beside it.
    @State private var topBarsHeight: CGFloat = 0
    #endif

    // The content is as wide as the view even with nothing in it yet: the scroll view takes its
    // content's width, and a status laid over the view, as a list's load failure, would be
    // squeezed into a column a few letters wide.
    var body: some View {
        #if os(tvOS)
        ScrollView { content.frame(maxWidth: .infinity) }
            .ignoresSafeArea(edges: edges)
        #else
        ScrollView { content.frame(maxWidth: .infinity).environment(\.topBarsHeight, underTopBars ? topBarsHeight : 0) }
            .ignoresSafeArea(edges: edges)
            // Measured outside the edge given up: inside, the bars would read as none at all.
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topBarsHeight = $0 }
        #endif
    }

    /// The parts of the safe area the scroll view gives up: Apple TV's overscan margin at the
    /// sides, and the bars over the top when `underTopBars`.
    private var edges: Edge.Set {
        #if os(tvOS)
        underTopBars ? [.horizontal, .top] : .horizontal
        #else
        underTopBars ? .top : []
        #endif
    }
}

extension EnvironmentValues {
    /// How far the bars over the top of an `EdgeToEdgeScrollView` that runs up under them reach
    /// over its content; zero in one that doesn't.
    @Entry var topBarsHeight: CGFloat = 0
}

extension View {
    /// The page's color behind a screen, under the bars too: the one its hero artwork fades into
    /// (see `Color.pageBackground`), so moving between screens doesn't change it. On Apple TV
    /// that's black, where the system's would be gray.
    func pageBackground() -> some View {
        background(Color.pageBackground.ignoresSafeArea())
    }
}
