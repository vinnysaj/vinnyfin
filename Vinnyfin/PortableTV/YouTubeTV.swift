#if os(macOS)
import AppKit
import Observation
import OSLog
import WebKit

/// YouTube's website on Portable TV, as Safari shows it to anyone: the app says it's Safari's
/// engine, which it is, and gets the site Google makes for it. YouTube's TV interface is only for
/// the TVs Google makes it for, and an app that claims to be one breaks YouTube's terms and the
/// App Store's rules for other services' content (5.2.2, 5.2.3), so the website it is.
///
/// The website is made for a pointer, so the remote moves one, clicks and scrolls, and plays,
/// pauses and skips with YouTube's own keys. It stays on YouTube, and Google's pages for signing
/// in and for consent: a link anywhere else does nothing, so the app gives no way out onto the web.
@Observable
final class YouTubeTV {
    /// The keys of YouTube's shortcuts the remote's buttons press.
    enum Key {
        case playPause, back10, forward10, fullScreen, escape, enter
        case arrow(TVDirection)

        /// The key's virtual key code and the characters it types.
        fileprivate var code: (UInt16, String) {
            switch self {
            case .playPause: (40, "k")
            case .back10: (38, "j")
            case .forward10: (37, "l")
            case .fullScreen: (3, "f")
            case .escape: (53, "\u{1b}")
            case .enter: (36, "\r")
            case .arrow(.up): (126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .arrow(.down): (125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
            case .arrow(.left): (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .arrow(.right): (124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
            }
        }
    }

    static let home = URL(string: "https://www.youtube.com/")!

    /// Where the pointer is, in fractions of the page's width and height from its top left; nil
    /// while it's hidden, as it is a few seconds after it last moved.
    private(set) var pointer: CGPoint?

    @ObservationIgnored private(set) lazy var webView = makeWebView()
    @ObservationIgnored private let navigation = Navigation()
    @ObservationIgnored private var hidesPointer: Task<Void, Never>?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "portable-tv")

    /// Loads YouTube the first time it shows, and takes the keyboard.
    func show() {
        if webView.url == nil { webView.load(URLRequest(url: Self.home)) }
        takeKeyboard()
    }

    func goHome() {
        webView.load(URLRequest(url: Self.home))
    }

    func search(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, var components = URLComponents(string: "https://www.youtube.com/results") else { return }
        components.queryItems = [URLQueryItem(name: "search_query", value: term)]
        if let url = components.url { webView.load(URLRequest(url: url)) }
    }

    /// Pauses what plays, as YouTube goes out of sight.
    func pauseVideos() {
        guard webView.url != nil else { return }
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(video => video.pause())") { _, error in
            if let error { Self.log.notice("Couldn't pause YouTube: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func press(_ press: TVPress) {
        switch press {
        case .point(let x, let y):
            movePointer(to: CGPoint(x: x, y: y))
        case .click(let x, let y):
            movePointer(to: CGPoint(x: x, y: y))
            click()
        case .scroll(let dx, let dy):
            scroll(dx: dx, dy: dy)
        case .select:
            // A pointer that's showing clicks; Select from a remote without one presses Return.
            if pointer != nil { click() } else { self.press(key: .enter) }
        case .back:
            if webView.fullscreenState == .inFullscreen || webView.fullscreenState == .enteringFullscreen {
                self.press(key: .escape)
            } else if webView.canGoBack {
                webView.goBack()
            }
        case .up: self.press(key: .arrow(.up))
        case .down: self.press(key: .arrow(.down))
        case .left: self.press(key: .arrow(.left))
        case .right: self.press(key: .arrow(.right))
        case .fullScreen: self.press(key: .fullScreen)
        case .home: goHome()
        case .text(let text): search(text)
        }
    }

    /// Presses a key on the page, as the Mac's keyboard would.
    func press(key: Key) {
        takeKeyboard()
        let (code, characters) = key.code
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: webView.window?.windowNumber ?? 0, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    /// The page is bigger on a big screen, so it reads from across the room.
    func fit(width: CGFloat) {
        let zoom = min(1.6, max(1, width / 1536))
        if abs(webView.pageZoom - zoom) > 0.01 { webView.pageZoom = zoom }
    }

    // MARK: Pointer

    private func movePointer(to point: CGPoint) {
        let point = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        pointer = point
        // The page's hover effects, as a mouse moving there shows them.
        send(mouse: .mouseMoved, at: point)
        hidesPointer?.cancel()
        hidesPointer = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { pointer = nil }
        }
    }

    private func click() {
        let point = pointer ?? CGPoint(x: 0.5, y: 0.5)
        takeKeyboard()
        send(mouse: .leftMouseDown, at: point)
        send(mouse: .leftMouseUp, at: point)
    }

    private func scroll(dx: Double, dy: Double) {
        guard let window = webView.window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: Int(-dy.rounded())), wheel2: Int32(clamping: Int(-dx.rounded())), wheel3: 0)
        else { return }
        // WebKit scrolls what's under the event's place on the screen, which a scroll has in
        // Quartz's coordinates: from the top left of the screen with the menu bar.
        let onScreen = window.convertPoint(toScreen: windowPoint(pointer ?? CGPoint(x: 0.5, y: 0.5)))
        let menuBarScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: onScreen.x, y: menuBarScreenHeight - onScreen.y)
        if let scroll = NSEvent(cgEvent: event) { webView.scrollWheel(with: scroll) }
    }

    private func send(mouse type: NSEvent.EventType, at point: CGPoint) {
        guard let window = webView.window,
              let event = NSEvent.mouseEvent(with: type, location: windowPoint(point), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        else { return }
        switch type {
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        default: webView.mouseMoved(with: event)
        }
    }

    /// A place on the page, in fractions from its top left, in the window's coordinates.
    private func windowPoint(_ point: CGPoint) -> CGPoint {
        let bounds = webView.bounds
        let y = webView.isFlipped ? point.y * bounds.height : (1 - point.y) * bounds.height
        return webView.convert(CGPoint(x: point.x * bounds.width, y: y), to: nil)
    }

    /// Keys go to the page, which ignores them while it isn't the window's first responder.
    private func takeKeyboard() {
        guard let window = webView.window, window.firstResponder !== webView else { return }
        window.makeFirstResponder(webView)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Safari's version on the end, as Safari has it: YouTube serves an engine without one an
        // older site.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // The remote's clicks are a person's, so videos play when they start them.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .black
        return webView
    }

    /// Keeps the page on YouTube, and opens what YouTube opens in a new window in its place.
    private final class Navigation: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Frames inside the page, such as its player and its sign-in, load from where YouTube says.
            guard action.targetFrame?.isMainFrame != false else { return .allow }
            guard let url = action.request.url, YouTubeTV.allows(url) else {
                YouTubeTV.log.info("Kept YouTube from leaving for \(action.request.url?.host() ?? "nowhere", privacy: .public)")
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, YouTubeTV.allows(url) { webView.load(action.request) }
            return nil
        }
    }

    /// The places the page may go: YouTube, and Google's pages for signing in and for consent.
    nonisolated static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return url.scheme == "about" }
        func within(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        return within("youtube.com") || within("youtu.be") || host == "accounts.google.com" || host == "consent.google.com"
    }
}
#endif
