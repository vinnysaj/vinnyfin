#if os(macOS)
import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Portable TV's screen width over the 1920 points it's laid out for, which its sizes scale by.
    @Entry var tvScale: CGFloat = 1
}

/// Portable TV's window: full screen on the TV the Mac is plugged into, with the library or
/// YouTube, and the player over them. Opening it turns Portable TV on, and closing it off.
struct PortableTVWindow: View {
    static let id = "portable-tv"

    @Environment(PortableTV.self) private var tv
    @Environment(AccountStore.self) private var accounts
    @Environment(SessionSocket.self) private var socket
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var hasKeyboardFocus: Bool
    /// Says how to use the remote, for a while after the TV comes on.
    @State private var showsHint = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                switch tv.space {
                case .library:
                    TVLibraryView(browser: tv.browser)
                case .youTube:
                    TVYouTubeView(youTube: tv.youTube)
                }
                if let model = tv.playing {
                    PlayerView(model: model) { Task { await tv.stopPlaying() } }
                        .environment(\.playerControlsRequests, tv.controlsRequests)
                        .id(model.id)
                }
                if showsHint, tv.playing == nil {
                    hint.frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .environment(\.tvScale, max(0.5, geometry.size.width / 1920))
        }
        .ignoresSafeArea()
        .environment(\.session, accounts.session)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(phases: [.down, .repeat]) { press in keyPressed(press) }
        .background(TVWindowPlacement())
        .navigationTitle("Portable TV")
        .preferredColorScheme(.dark)
        .onAppear { tv.turnOn() }
        .onDisappear { Task { await tv.turnOff() } }
        // The remote's presses come over the socket, which stays open with this window alone.
        .task(id: signIn) {
            guard let client = accounts.client else { return }
            await socket.hold(client: client)
        }
        .task {
            try? await Task.sleep(for: .seconds(12))
            withAnimation { showsHint = false }
        }
        .onChange(of: player.pendingTVRequest, initial: true) { _, request in
            guard let request else { return }
            player.pendingTVRequest = nil
            // The one engine plays one thing: what plays on the TV replaces a player window's.
            dismissWindow(id: PlayerWindow.id)
            tv.play(request)
        }
        // The library takes the Mac's keys; YouTube's page and the player take their own.
        .onChange(of: takesKeys, initial: true) { _, takes in hasKeyboardFocus = takes }
    }

    private var takesKeys: Bool { tv.space == .library && tv.playing == nil }

    private var signIn: String? {
        guard let client = accounts.client else { return nil }
        return "\(client.serverURL.absoluteString) \(client.token ?? "")"
    }

    private var hint: some View {
        TVHint()
            .padding(.bottom, 60)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    /// The Mac's arrows, Return and Escape press as a remote's would; letters search.
    private func keyPressed(_ press: KeyPress) -> KeyPress.Result {
        guard takesKeys else { return .ignored }
        switch press.key {
        case .upArrow: tv.press(.up)
        case .downArrow: tv.press(.down)
        case .leftArrow: tv.press(.left)
        case .rightArrow: tv.press(.right)
        case .return, .space where tv.browser.tab != .search || tv.browser.focusesTabs || !tv.browser.pages.isEmpty: tv.press(.select)
        case .escape: tv.press(.back)
        case .delete: tv.browser.deleteBackward()
        default:
            guard press.modifiers.subtracting(.shift).isEmpty, press.phase == .down,
                  press.characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " })
            else { return .ignored }
            tv.browser.type(press.characters)
        }
        return .handled
    }
}

/// How to drive the TV, along the bottom as it comes on.
private struct TVHint: View {
    @Environment(\.tvScale) private var scale

    var body: some View {
        Label {
            Text("Open vinnyfin on your iPhone and tap \(Image(systemName: "appletvremote.gen4")) to use it as the remote, or use this Mac's arrow keys.")
        } icon: {
            Image(systemName: "appletvremote.gen4.fill")
        }
        .font(.system(size: 24 * scale, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 28 * scale)
        .padding(.vertical, 16 * scale)
        .background(.black.opacity(0.7), in: .capsule)
    }
}

/// Moves the window to the TV and fills it: to a screen other than the library window's,
/// preferring one that isn't built in, else full screen where it is.
private struct TVWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacingView { PlacingView() }
    func updateNSView(_ view: PlacingView, context: Context) {}

    final class PlacingView: NSView {
        private var placed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !placed else { return }
            placed = true
            // Once the window is on screen, which full screen needs.
            DispatchQueue.main.async { Self.place(window) }
        }

        private static func place(_ window: NSWindow) {
            let library = NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeMain }?.screen
            let others = NSScreen.screens.filter { $0 != library }
            if let tv = others.first(where: { !$0.isBuiltIn }) ?? others.first, tv != window.screen {
                window.setFrame(tv.visibleFrame, display: true)
            }
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }
}

private extension NSScreen {
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}
#endif
