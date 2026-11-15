import AppIntents
import SwiftUI

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(KnownServers.self) private var knownServers
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @Environment(WatchHistory.self) private var history
    @Environment(AppSettings.self) private var settings
    @Environment(IncomingLinks.self) private var links
    @Environment(SessionSocket.self) private var socket
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS) || os(macOS)
    @Environment(RemoteControl.self) private var remote
    #endif
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #elseif os(visionOS)
    @Environment(\.pushWindow) private var pushWindow
    #endif
    #if !os(tvOS)
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadManager.self) private var downloads
    @Environment(SpotlightTitles.self) private var spotlight
    #endif
    /// A title a link or another device asked to open, which may be from another sign-in.
    @State private var titleFromSignIn: TitleFromSignIn?
    /// A title a link asked to open, for the tab on screen to show.
    @State private var linkedItem: JellyfinItem?
    /// What Spotlight or Siri asked to search for, for the Search tab.
    @State private var linkedSearch: String?
    #if os(iOS)
    /// The full-screen player is up, until it has finished going away.
    @State private var playerCovers = false
    #endif

    private var session: ServerSession? { accounts.session }

    var body: some View {
        @Bindable var player = player
        @Bindable var messages = messages
        Group {
            if let session {
                MainTabs(linkedItem: $linkedItem, linkedSearch: $linkedSearch)
                    // Each server and user gets fresh browsing state.
                    .id(session.account.serverId + session.account.userId)
            } else {
                WelcomeView()
            }
        }
        .environment(\.session, session)
        .preferredColorScheme(settings.appearance.colorScheme)
        #if os(macOS) || os(visionOS)
        .onChange(of: player.pendingWindowRequest) { _, request in
            guard let request else { return }
            player.pendingWindowRequest = nil
            #if os(visionOS)
            // The player takes this window's place, and closing it brings the library back.
            pushWindow(id: PlayerWindow.id, value: request)
            #else
            // One engine plays one thing: a new playback replaces the window of the last.
            dismissWindow(id: PlayerWindow.id)
            openWindow(id: PlayerWindow.id, value: request)
            #endif
        }
        #else
        // Away while its playback plays in Picture in Picture (`PlayerCoordinator.isInPictureInPicture`).
        .fullScreenCover(item: $player.coverModel) {
            #if os(iOS)
            playerCovers = false
            #endif
        } content: { model in
            PlayerView(model: model) { Task { await player.dismiss() } }
                .environment(\.session, session)
                #if os(iOS)
                .onAppear { playerCovers = true }
                #endif
        }
        #endif
        .alert("Something Went Wrong", isPresented: Binding(get: { messages.current != nil }, set: { if !$0 { messages.current = nil } })) {
            Button("OK") { messages.current = nil }
        } message: {
            Text(messages.current ?? "")
        }
        .alert(messages.confirmation?.title ?? "", isPresented: Binding(get: { messages.confirmation != nil },
                                                                        set: { if !$0 { messages.confirmation = nil } }),
               presenting: messages.confirmation) { confirmation in
            Button(confirmation.action, action: confirmation.perform)
                .accessibilityIdentifier("confirmation.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert("Save Password to iCloud?", isPresented: Binding(get: { knownServers.passwordOffer != nil },
                                                                 set: { if !$0 { knownServers.passwordOffer = nil } }),
               presenting: knownServers.passwordOffer) { offer in
            Button("Save Password") { knownServers.save(offer) }
                .accessibilityIdentifier("savePassword.save")
            Button("Not Now", role: .cancel) {}
        } message: { _ in
            Text("vinnyfin will sign you in automatically on your other devices that use it with your iCloud.")
        }
        .alert("Can't Play", isPresented: Binding(get: { player.problem != nil }, set: { if !$0 { player.problem = nil } })) {
            Button("OK") { player.problem = nil }
        } message: {
            Text(player.problem ?? "")
        }
        .watchTogetherAlerts()
        #if !os(tvOS)
        .alert("Download a Transcode?", isPresented: Binding(get: { downloads.transcodes.proposal != nil },
                                                             set: { if !$0 { downloads.transcodes.proposal = nil } }),
               presenting: downloads.transcodes.proposal) { proposal in
            Button("Download Transcode") { downloads.enqueue(proposal.item, plan: proposal.plan, startedByUser: true) }
                .accessibilityIdentifier("transcode.download")
            Button("Download As It Is (\(proposal.original.summary))") {
                downloads.enqueue(proposal.item, plan: proposal.original, startedByUser: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { proposal in
            Text(proposal.message)
        }
        #endif
        #if os(iOS) || os(macOS)
        .sheet(isPresented: showsRemoteScreen) {
            RemoteScreen()
                .environment(\.session, session)
        }
        #endif
        // Others can play to this device while it's open, or while it plays in the background.
        .task(id: socketConnection) {
            guard socketConnection != nil, let client = accounts.client else { return }
            await socket.hold(client: client)
        }
        .onOpenURL { url in open(url) }
        // A tapped notification, Siri, Shortcuts, Spotlight and Handoff open titles as a link would.
        .onChange(of: links.pending, initial: true) { _, incoming in
            guard let incoming else { return }
            links.pending = nil
            follow(incoming)
        }
        #if !os(tvOS)
        .onContinueUserActivity(Handoff.activityType) { activity in
            guard let handoff = Handoff(activity) else {
                messages.show("vinnyfin can't continue what your other device handed over. Updating vinnyfin on both may help.")
                return
            }
            links.open(handoff)
        }
        #endif
        .opensTitlesUnderTheirSignIn($titleFromSignIn) { link in open(link) }
        #if os(macOS)
        // Links and handed-off titles open in the window that's open, rather than in a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        #endif
        // Runs while the app is open, and stops as it goes to the background. Another sign-in
        // starts it over, to send what that one watched offline and plan its smart downloads.
        .task(id: OpenWork(isOpen: scenePhase != .background, signIn: accounts.account?.tokenKey)) {
            guard scenePhase != .background else {
                #if os(tvOS)
                TopShelf.reload()
                #elseif os(iOS)
                UpNextWidgets.reload()
                #endif
                // What's being watched, which Siri's phrases name, may have changed while it was open.
                VinnyfinShortcuts.updateAppShortcutParameters()
                return
            }
            // What was watched offline goes to the server first, so smart downloads plan from it.
            if let session { await history.syncPending(using: session.client, userId: session.userId) }
            #if !os(tvOS)
            async let spotlightRefresh: Void = spotlight.refreshWhileOpen()
            await smartDownloads.refreshWhileOpen()
            await spotlightRefresh
            #endif
        }
    }

    #if os(iOS) || os(macOS)
    /// The remote's screen. On iPhone and iPad it waits for the player that handed its playback
    /// over to be gone: a sheet presented over the full-screen player keeps it from closing, and
    /// one presented while it goes takes on its dark appearance on a light sheet.
    private var showsRemoteScreen: Binding<Bool> {
        Binding {
            #if os(iOS)
            remote.showsScreen && !playerCovers
            #else
            remote.showsScreen
            #endif
        } set: {
            remote.showsScreen = $0
        }
    }
    #endif

    /// The sign-in the socket is open for; nil while it's closed: signed out, or in the background
    /// with nothing playing, when the server then stops listing this device to play to. On the
    /// Mac, which doesn't suspend apps, it stays open.
    private var socketConnection: String? {
        guard let client = accounts.client, let account = accounts.account else { return nil }
        #if !os(macOS)
        if scenePhase == .background, player.presented?.isPlaying != true { return nil }
        #endif
        return "\(client.serverURL.absoluteString) \(account.userId) \(client.token ?? "")"
    }

    /// Plays a file, or follows a vinnyfin:// link.
    private func open(_ url: URL) {
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            player.playFile(url)
        } else if let link = AppLink(url) {
            open(link)
        } else {
            messages.show("vinnyfin can't open \(url.absoluteString).")
        }
    }

    /// Plays the title, or shows its page on the tab on screen. A player covering the tabs closes
    /// for it; one in Picture in Picture, or in a window of its own, plays on. A title from
    /// another sign-in opens under its own (`opensTitlesUnderTheirSignIn`).
    private func open(_ link: AppLink) {
        if let owner = link.owner, !owner.isSignedIn(as: accounts.account) {
            titleFromSignIn = .link(link)
            return
        }
        switch link.action {
        case .play:
            player.play(.item(link.item, continuingFrom: link.position))
        case .open:
            guard session != nil else {
                messages.show("Sign in to see \(link.name).")
                return
            }
            if player.coversScreens {
                Task { await player.dismiss() }
            }
            linkedItem = link.item
        }
    }

    private func follow(_ incoming: IncomingLinks.Incoming) {
        switch incoming {
        case .link(let url):
            open(url)
        case .search(let term):
            guard session != nil else {
                messages.show("Sign in to search for \(term).")
                return
            }
            if player.coversScreens {
                Task { await player.dismiss() }
            }
            linkedSearch = term
        #if !os(tvOS)
        case .handoff(let handoff):
            titleFromSignIn = .handoff(handoff)
        #endif
        }
    }
}

struct MainTabs: View {
    enum Destination: Hashable {
        case home, movies, shows, downloads, sounds, settings, search
    }

    /// A title a link asked to open, shown on the tab on screen as the page after the one it shows.
    @Binding var linkedItem: JellyfinItem?
    /// What Spotlight or Siri asked to search for, which the Search tab searches for.
    @Binding var linkedSearch: String?
    @State private var navigation = TabNavigation()
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerCoordinator.self) private var player
    /// The Go menu's Search commands so far, each of which puts the cursor in the search field.
    @State private var searchFieldRequests = 0
    #endif
    #if os(iOS) || os(macOS)
    @Environment(RemoteControl.self) private var remote
    #endif

    var body: some View {
        tabs
            #if os(iOS)
            .tabViewBottomAccessory(isEnabled: remote.isActive) { RemoteMiniPlayer() }
            #elseif os(macOS)
            .safeAreaInset(edge: .bottom) {
                if remote.isActive {
                    RemoteMiniPlayer()
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
            #endif
    }

    private var tabs: some View {
        TabView(selection: $navigation.selection) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeView(path: $navigation.home) { navigation.selection = .downloads }
                    .undoToasts()
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                NavigationStack(path: $navigation.movies) {
                    LibraryGridView(list: .movies).itemDestinations()
                }
                .opensTitles(on: $navigation.movies)
                .undoToasts()
            }
            Tab("Shows", systemImage: "tv", value: .shows) {
                NavigationStack(path: $navigation.shows) {
                    LibraryGridView(list: .shows).itemDestinations()
                }
                .opensTitles(on: $navigation.shows)
                .undoToasts()
            }
            #if os(tvOS)
            Tab("Sounds", systemImage: "waveform", value: .sounds) {
                SoundsView()
            }
            Tab("Settings", systemImage: "gear", value: .settings) {
                SettingsView()
            }
            #else
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                DownloadsView(path: $navigation.downloads)
                    .undoToasts()
            }
            .badge(downloads.jobs.count { $0.status == .active })
            #endif
            #if os(iOS) || os(visionOS)
            if Self.hasSettingsTab {
                Tab("Settings", systemImage: "gear", value: .settings) {
                    SettingsView()
                }
            }
            #endif
            Tab(value: .search, role: .search) {
                Group {
                    #if os(tvOS)
                    SearchView(request: navigation.searchRequest, path: $navigation.search)
                    #else
                    SearchView(fieldRequests: searchFieldRequests, request: navigation.searchRequest, path: $navigation.search)
                    #endif
                }
                .undoToasts()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        // On iPhone the bar shrinks as a page scrolls down, out of the way of the cards under it.
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        #if !os(tvOS)
        // While the player covers the tabs, the Go menu waits for it to close.
        .focusedSceneValue(\.tabs, player.coversScreens ? nil : TabCommandTarget(go: go, back: back))
        #endif
        .onChange(of: linkedItem, initial: true) {
            guard let linkedItem else { return }
            navigation.open(linkedItem)
            self.linkedItem = nil
        }
        .onChange(of: linkedSearch, initial: true) {
            guard let linkedSearch else { return }
            navigation.search(for: linkedSearch)
            self.linkedSearch = nil
        }
    }

    #if os(iOS) || os(visionOS)
    /// Settings is a tab where there's a sidebar to hold it, as on Apple TV: on iPad and Vision
    /// Pro. On iPhone it opens from Home, and on the Mac in a window of its own.
    static var hasSettingsTab: Bool {
        #if os(visionOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
    #endif

    #if !os(tvOS)
    private func go(_ command: TabCommand) {
        navigation.selection = command.destination
        if command == .search { searchFieldRequests += 1 }
    }

    /// The Go menu's Back: a page back in the tab showing, when it's past its first.
    private var back: (() -> Void)? {
        let path: WritableKeyPath<TabNavigation, NavigationPath>
        switch navigation.selection {
        case .home: path = \.home
        case .movies: path = \.movies
        case .shows: path = \.shows
        case .downloads: path = \.downloads
        case .search: path = \.search
        case .sounds, .settings: return nil
        }
        guard !navigation[keyPath: path].isEmpty else { return nil }
        return { navigation[keyPath: path].removeLast() }
    }
    #endif
}

/// The tab on screen, the pages open on each tab, and where a title a link asks for opens.
struct TabNavigation {
    var selection = MainTabs.Destination.home
    var home = NavigationPath()
    var movies = NavigationPath()
    var shows = NavigationPath()
    var downloads = NavigationPath()
    var search = NavigationPath()
    /// The last search asked for from outside the app, which the Search tab shows.
    private(set) var searchRequest: SearchRequest?

    /// Shows the Search tab searching for `term`, as Spotlight and Siri ask, back on its results
    /// from any page open over them.
    mutating func search(for term: String) {
        selection = .search
        search = NavigationPath()
        searchRequest = SearchRequest(term: term)
    }

    /// Opens a title a link asked for as the next page of the tab on screen, so what that tab
    /// showed stays a page back. A tab with no pages of titles, Sounds or Settings, gives way to
    /// Home.
    mutating func open(_ item: JellyfinItem) {
        switch selection {
        case .home: home.append(item)
        case .movies: movies.append(item)
        case .shows: shows.append(item)
        case .downloads: downloads.append(item)
        case .search: search.append(item)
        case .sounds, .settings:
            selection = .home
            home.append(item)
        }
    }
}

/// A search asked for from outside the app. Each is new, so asking for the same term again
/// searches for it again.
struct SearchRequest: Equatable {
    let term: String
    let id = UUID()
}

extension AppSettings.Appearance {
    /// Nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// What the work done while the app is open depends on: whether it's open, and who's signed in.
private struct OpenWork: Equatable {
    let isOpen: Bool
    let signIn: String?
}
