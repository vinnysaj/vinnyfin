import AppIntents
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if os(visionOS)
import GroupActivities
#endif

@main
struct VinnyfinApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(visionOS)
    @State private var cinemaImmersion: any ImmersionStyle = .progressive(0.2...1, initialAmount: 1)
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .withAppEnvironment(appDelegate)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
        #if !os(tvOS)
        .commands {
            #if os(macOS)
            // After New Window, which opens another library window.
            CommandGroup(after: .newItem) {
                Button("Open File…") { appDelegate.openFilePanel() }
                    .keyboardShortcut("o")
            }
            #endif
            SidebarCommands()
            AppCommands()
            #if os(macOS)
            PortableTVCommands(tv: appDelegate.portableTV)
            #endif
        }
        #endif

        #if os(macOS) || os(visionOS)
        WindowGroup("Player", id: PlayerWindow.id, for: PlaybackRequest.self) { $request in
            PlayerWindow(request: request)
                .withAppEnvironment(appDelegate)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        #else
        // The picture is the window, with no glass around it, and the window keeps its shape.
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        #endif
        .restorationBehavior(.disabled)
        #endif

        #if os(visionOS)
        ImmersiveSpace(id: CinemaSpace.id) {
            CinemaSpace()
                .withAppEnvironment(appDelegate)
        }
        // The Digital Crown brings the room back in around the theater.
        .immersionStyle(selection: $cinemaImmersion, in: .progressive)
        #endif

        #if os(macOS)
        Window("Portable TV", id: PortableTVWindow.id) {
            PortableTVWindow()
                .withAppEnvironment(appDelegate)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .withAppEnvironment(appDelegate)
        }
        #endif
    }
}

extension View {
    /// The app's shared state, for every window.
    func withAppEnvironment(_ app: AppDelegate) -> some View {
        #if os(tvOS)
        environment(app.accounts)
            .environment(app.knownServers)
            .environment(app.settings)
            .environment(app.history)
            .environment(app.messages)
            .environment(app.links)
            .environment(app.player)
            .environment(app.socket)
            .environment(app.sharePlay)
            .environment(app.sounds)
        #else
        environment(app.accounts)
            .environment(app.knownServers)
            .environment(app.settings)
            .environment(app.history)
            .environment(app.messages)
            .environment(app.links)
            .environment(app.player)
            .environment(app.socket)
            .environment(app.sharePlay)
            .environment(app.sounds)
            .environment(app.downloads)
            .environment(app.downloadNotifications)
            .environment(app.smartDownloads)
            .environment(app.localLibrary)
            .environment(app.spotlight)
            #if os(iOS) || os(visionOS)
            .environment(app.backgroundDownloads)
            .environment(app.diagnostics)
            #endif
            #if os(iOS) || os(macOS)
            .environment(app.widgetDownloads)
            .environment(app.remote)
            #endif
            #if os(macOS)
            .environment(app.portableTV)
            #elseif os(iOS)
            .environment(app.tvRemote)
            #endif
        #endif
    }
}

/// Owns the app's state from launch, including the background launches the system makes
/// to hand over finished transfers or run a background task, when no window may be shown.
final class AppDelegate: NSObject {
    let settings = AppSettings(cloud: NSUbiquitousKeyValueStore.default)
    #if os(iOS) || os(macOS)
    let accounts = AccountStore(movingSignInFrom: .standard)
    #else
    let accounts = AccountStore()
    #endif
    private(set) lazy var history = WatchHistory { [accounts] in accounts.account?.tokenKey }
    let messages = AppMessages()
    let links = IncomingLinks()
    private(set) lazy var knownServers = KnownServers(accounts: accounts, cloud: NSUbiquitousKeyValueStore.default)
    private lazy var cloudSync = CloudSync(store: .default, settings: settings, servers: knownServers, messages: messages)
    #if os(tvOS)
    private(set) lazy var player = PlayerCoordinator(accounts: accounts, settings: settings, history: history)
    private(set) lazy var sounds = SoundPlayer(settings: settings, player: player)
    #else
    private(set) lazy var downloadNotifications = DownloadNotifications(settings: settings, links: links)
    private(set) lazy var downloads = DownloadManager(accounts: accounts, settings: settings, history: history,
                                                      notifications: downloadNotifications)
    private(set) lazy var smartDownloads = SmartDownloads(accounts: accounts, downloads: downloads, settings: settings, history: history)
    let localLibrary = LocalLibrary()
    private(set) lazy var player = PlayerCoordinator(accounts: accounts, settings: settings, history: history,
                                                     downloads: downloads, smartDownloads: smartDownloads, localLibrary: localLibrary)
    private(set) lazy var spotlight = SpotlightTitles(accounts: accounts, downloads: downloads)
    private(set) lazy var sounds = SoundPlayer(settings: settings, player: player, downloads: downloads)
    #endif
    #if os(iOS) || os(visionOS)
    private(set) lazy var backgroundDownloads = BackgroundDownloads(downloads: downloads, smartDownloads: smartDownloads)
    let diagnostics = AppDiagnostics()
    #endif
    /// Jellyfin's remote control: other devices play to this one, and this one to them.
    let socket = SessionSocket()
    private(set) lazy var sharePlay = SharePlay(accounts: accounts, player: player)
    #if os(iOS) || os(macOS)
    private(set) lazy var remote = RemoteControl(accounts: accounts, socket: socket, player: player)
    private(set) lazy var widgetDownloads = WidgetDownloads(downloads: downloads, history: history)
    #endif
    #if os(macOS)
    private(set) lazy var portableTV = PortableTV(accounts: accounts, player: player, socket: socket)
    #elseif os(iOS)
    private(set) lazy var tvRemote = TVRemote(accounts: accounts)
    #endif

    private func launched() {
        ImageCache.configure()
        StreamingNetwork.follow()
        if let problem = accounts.savedSignInProblem { messages.show(problem) }
        #if os(iOS) || os(macOS)
        if let problem = accounts.sharingProblem { messages.show(problem) }
        #endif
        // Siri, Shortcuts, Spotlight and the Downloads control act on these, also with the app in
        // the background.
        let accounts = accounts
        let links = links
        AppDependencyManager.shared.add(dependency: accounts)
        AppDependencyManager.shared.add(dependency: links)
        let cloudSync = cloudSync
        Task { await cloudSync.run() }
        let knownServers = knownServers
        Task { await knownServers.followSignIns() }
        let player = player
        player.sharePlay = sharePlay
        #if os(macOS)
        // Portable TV takes its remote's presses, and the transport while YouTube shows.
        let portableTV = portableTV
        socket.onCommand = { command in
            if !portableTV.handle(command) { player.perform(command) }
        }
        #else
        socket.onCommand = { command in player.perform(command) }
        #endif
        // From launch, so a session started on FaceTime before the app opened is joined.
        let sharePlay = sharePlay
        Task { await sharePlay.run() }
        let sounds = sounds
        Task { await sounds.run() }
        #if !os(tvOS)
        downloadNotifications.start()
        let settings = settings
        let history = history
        let downloads = downloads
        let smartDownloads = smartDownloads
        let spotlight = spotlight
        AppDependencyManager.shared.add(dependency: settings)
        AppDependencyManager.shared.add(dependency: history)
        AppDependencyManager.shared.add(dependency: downloads)
        AppDependencyManager.shared.add(dependency: smartDownloads)
        AppDependencyManager.shared.add(dependency: spotlight)
        Task { await downloads.run() }
        Task { await downloads.trackProgress() }
        Task { await spotlight.run() }
        #endif
        #if os(iOS) || os(macOS)
        let widgetDownloads = widgetDownloads
        AppDependencyManager.shared.add(dependency: widgetDownloads as any DownloadsRunning)
        Task { await widgetDownloads.run() }
        #endif
        #if os(iOS) || os(visionOS)
        backgroundDownloads.registerLaunchHandlers()
        let backgroundDownloads = backgroundDownloads
        Task { await backgroundDownloads.run() }
        let diagnostics = diagnostics
        Task { await diagnostics.run() }
        #endif
    }

    #if os(macOS)
    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DownloadsView.videoTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.playFile(url)
    }
    #endif
}

#if os(macOS)
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        launched()
    }

    /// The desktop's widgets come into view as another app takes over.
    func applicationDidResignActive(_ notification: Notification) {
        UpNextWidgets.reload()
    }
}
#else
extension AppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        launched()
        return true
    }

    #if os(iOS)
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerOrientationLock.allowed
    }
    #endif

    #if !os(tvOS)
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        downloads.handleBackgroundEvents(completion: completionHandler)
    }
    #endif
}
#endif

#if os(macOS) || os(visionOS)
/// A player window on the Mac and Vision Pro, one per playback.
struct PlayerWindow: View {
    static let id = "player"
    let request: PlaybackRequest?

    @Environment(PlayerCoordinator.self) private var player
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismissWindow) private var dismissWindow
    #if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif
    @State private var model: PlayerModel?

    var body: some View {
        Group {
            if let model {
                PlayerView(model: model) { dismissWindow() }
            } else {
                Color.black
            }
        }
        .environment(\.session, accounts.session)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 270)
        #else
        // Shaped like the picture, which then fills it edge to edge, at any size it's pulled to.
        .aspectRatio(pictureAspectRatio, contentMode: .fit)
        .frame(minWidth: 640, idealWidth: 1280, maxWidth: 3200)
        // Watching together, the Spatial Personas gather around this window.
        .groupActivityAssociation(.primary(PlayerWindow.id))
        #endif
        .navigationTitle(model?.title ?? request?.title ?? "vinnyfin")
        .onAppear {
            guard model == nil, let request else { return }
            model = player.makeModel(for: request)
            player.presented = model
        }
        .onDisappear {
            let closing = model
            model = nil
            if player.presented === closing { player.presented = nil }
            #if os(visionOS)
            if player.isInCinema { Task { await dismissImmersiveSpace() } }
            #endif
            Task { await closing?.close() }
        }
    }

    #if os(visionOS)
    /// 16:9 until the video says otherwise.
    private var pictureAspectRatio: CGFloat {
        guard let size = model?.videoSize, size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }
    #endif
}
#endif
