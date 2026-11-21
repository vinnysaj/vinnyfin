import SwiftUI

/// Something that couldn't load: what it was, as a title ("Couldn't Load the Show"), and why, in
/// words for the screen.
struct LoadFailure: Equatable {
    let title: String
    let message: String

    init(_ title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// Why from the error: a server's error answer reads as `JellyfinError.message(status:body:)`.
    init(_ title: String, error: any Error) {
        self.init(title, message: error.localizedDescription)
    }
}

/// In place of what couldn't load, filling its space: the system's own unavailable-content
/// layout, with Try Again, and any other way on beside it. On Apple TV the buttons are in a focus
/// section of their own, so the remote reaches them from wherever focus is on the screen.
struct LoadFailureView<More: View>: View {
    let failure: LoadFailure
    var systemImage = "exclamationmark.triangle"
    let retry: () -> Void
    @ViewBuilder var more: More

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: systemImage)
        } description: {
            Text(failure.message)
                .frame(maxWidth: Self.messageWidth)
        } actions: {
            LoadFailureActions(alignment: .center, isProminent: true, retry: retry) { more }
                #if os(tvOS)
                .focusSection()
                #else
                // The view's own actions are small, too small for the screen's one way on.
                .controlSize(.large)
                #endif
        }
        // The space it's given, whatever the size of what it stands in for.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Lines short enough to read across a wide screen.
    private static var messageWidth: CGFloat {
        #if os(tvOS)
        1100
        #else
        560
        #endif
    }
}

extension LoadFailureView where More == EmptyView {
    init(_ failure: LoadFailure, systemImage: String = "exclamationmark.triangle", retry: @escaping () -> Void) {
        self.init(failure: failure, systemImage: systemImage, retry: retry) { EmptyView() }
    }
}

/// A part of a page that couldn't load, where it would have been, the rest of the page around it:
/// on a card as wide as the page's text, the title by its symbol, why under it, then Try Again
/// and any other way on. Try Again isn't filled: the page's own main action, as Play, is.
struct LoadFailureNotice<More: View>: View {
    let failure: LoadFailure
    var systemImage = "exclamationmark.triangle"
    let retry: () -> Void
    @ViewBuilder var more: More

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.title, systemImage: systemImage)
                .font(.headline)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LoadFailureActions(isProminent: false, retry: retry) { more }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .noticeBackground()
        .accessibilityElement(children: .contain)
        #if os(tvOS)
        // Focus moving down the page lands on its buttons from anywhere across it.
        .focusSection()
        #endif
    }
}

extension LoadFailureNotice where More == EmptyView {
    init(_ failure: LoadFailure, systemImage: String = "exclamationmark.triangle", retry: @escaping () -> Void) {
        self.init(failure: failure, systemImage: systemImage, retry: retry) { EmptyView() }
    }
}

/// The buttons of a load failure: Try Again, then the other ways on, on glass like the app's other
/// buttons. A button's default style in a `ContentUnavailableView` or a plain stack is the
/// system's bordered platter on Apple TV and the Mac, so every one of them takes a glass style
/// here.
struct LoadFailureActions<More: View>: View {
    var alignment = HorizontalAlignment.leading
    /// Try Again filled with the accent color, as a screen's main action.
    var isProminent: Bool
    /// Try Again's focus, for a screen that puts focus on it as the failure appears.
    var retryFocus: FocusState<Bool>.Binding?
    let retry: () -> Void
    @ViewBuilder var more: More

    var body: some View {
        AdaptiveStack(alignment: alignment) {
            Group {
                if isProminent {
                    Button("Try Again", action: retry).buttonStyle(.platformGlassProminent)
                } else {
                    Button("Try Again", action: retry).buttonStyle(.platformGlass)
                }
            }
            .modifier(OptionalFocus(binding: retryFocus))
            .accessibilityIdentifier("failure.retry")
            more.buttonStyle(.platformGlass)
        }
    }
}

/// Binds a view's focus when there's a binding.
private struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}
