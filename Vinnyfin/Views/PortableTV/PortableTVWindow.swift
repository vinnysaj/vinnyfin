#if os(macOS)
import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Portable TV's screen width over the 1920 points it's laid out for, which its sizes scale by.
    @Entry var tvScale: CGFloat = 1
}

/// Portable TV's window: full screen on the TV the Mac is plugged into, with the library or
/// YouTube, and the player over them. Opening it turns Portable TV on, and closing it off, as
/// Escape does once there's nothing on the TV left for it to back out of, and unplugging the TV.
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
                TVVolumeHUD(volume: tv.volume)
                    .frame(maxHeight: .infinity, alignment: .top)
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
        .background(TVScreenWatch { dismissWindow(id: Self.id) })
        .background(EscapeKey(onPress: escapePressed))
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

    /// Escape backs out of a title's page, and with none open turns the TV off, as it does on
    /// YouTube. Not while something plays or a YouTube video fills the screen: the player and the
    /// page each end those with their own Escape.
    private func escapePressed() -> Bool {
        guard tv.playing == nil else { return false }
        switch tv.space {
        case .library where !tv.browser.pages.isEmpty: tv.press(.back)
        case .youTube where tv.youTube.fillsScreen: return false
        case .library, .youTube: dismissWindow(id: Self.id)
        }
        return true
    }

    /// The Mac's arrows and Return press as a remote's would; letters search.
    private func keyPressed(_ press: KeyPress) -> KeyPress.Result {
        guard takesKeys else { return .ignored }
        switch press.key {
        case .upArrow: tv.press(.up)
        case .downArrow: tv.press(.down)
        case .leftArrow: tv.press(.left)
        case .rightArrow: tv.press(.right)
        case .return, .space where tv.browser.tab != .search || tv.browser.focusesTabs || !tv.browser.pages.isEmpty: tv.press(.select)
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

/// The volume, at the top of the screen for a moment after each press that turns it.
private struct TVVolumeHUD: View {
    let volume: TVVolume
    @Environment(\.tvScale) private var scale
    @State private var isShown = false

    var body: some View {
        let level = volume.isMuted ? 0 : CGFloat(volume.level)
        HStack(spacing: 16 * scale) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
                .frame(width: 44 * scale)
            Capsule()
                .fill(.white.opacity(0.25))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: 260 * scale * level)
                }
                .frame(width: 260 * scale, height: 8 * scale)
        }
        .font(.system(size: 28 * scale, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 28 * scale)
        .padding(.vertical, 18 * scale)
        .background(.black.opacity(0.7), in: .capsule)
        .padding(.top, 60 * scale)
        .opacity(isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: isShown)
        .animation(.easeOut(duration: 0.15), value: level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: volume.presses) {
            guard volume.presses > 0 else { return }
            isShown = true
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { isShown = false }
        }
    }
}

/// Hears Escape pressed in its window before whatever there has the keyboard, which on YouTube
/// is the page, and it keeps the key.
private struct EscapeKey: NSViewRepresentable {
    /// Says whether it took the press; one it didn't goes on to what has the keyboard.
    let onPress: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            guard event.keyCode == Self.escape, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
                  let window = view?.window, event.window === window, coordinator?.onPress?() == true
            else { return event }
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onPress = onPress
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    final class Coordinator {
        var onPress: (() -> Bool)?
        var monitor: Any?
    }

    /// Escape's virtual key code.
    private static let escape: UInt16 = 53
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

/// Says when the screen its window is on has been gone a while, as when the TV is unplugged:
/// macOS moves the window to a screen that's left, full screen in a Space of its own, where it
/// would play on unseen and keep the Mac awake. A screen that's back within the while, as when
/// a TV drops its connection for a moment to change modes, is no matter.
private struct TVScreenWatch: NSViewRepresentable {
    let onGone: () -> Void

    func makeNSView(context: Context) -> WatchingView { WatchingView() }

    func updateNSView(_ view: WatchingView, context: Context) {
        view.onGone = onGone
    }

    final class WatchingView: NSView {
        var onGone: (() -> Void)?
        /// The display the window is on, which stays the one gone as macOS moves the window off it.
        private var display: CGDirectDisplayID?
        private var countdown: Task<Void, Never>?
        private var observers: [any NSObjectProtocol] = []

        private static let grace = Duration.seconds(10)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            countdown?.cancel()
            countdown = nil
            guard let window else { return }
            display = window.screen?.displayID
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowMoved(enteringFullScreen: false) }
                },
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowMoved(enteringFullScreen: true) }
                },
                center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                },
            ]
        }

        /// Placed on the TV, or going full screen there, the window takes its display. Full screen,
        /// a move is macOS taking it off a display that's gone, which may yet say it's connected.
        private func windowMoved(enteringFullScreen: Bool) {
            guard let window else { return }
            if enteringFullScreen || !window.styleMask.contains(.fullScreen) { display = window.screen?.displayID }
            check()
        }

        private func check() {
            guard let display, !Self.isConnected(display) else {
                countdown?.cancel()
                countdown = nil
                return
            }
            guard countdown == nil else { return }
            countdown = Task { [weak self] in
                try? await Task.sleep(for: Self.grace)
                if !Task.isCancelled { self?.onGone?() }
            }
        }

        private static func isConnected(_ display: CGDirectDisplayID) -> Bool {
            CGDisplayIsOnline(display) != 0
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool {
        displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }
}
#endif
