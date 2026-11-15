import Nuke
import SwiftUI

/// What to watch next, and everything else to find: a featured banner, what's in progress and
/// new, then a long run of rows from what was watched and liked, the best and newest, collections
/// and every genre. Continue Watching plays on a tap; every other card opens its title. A row's
/// title opens all of its titles when it holds only some.
struct HomeView: View {
    /// The pages open on top of Home: titles, and lists in full.
    @Binding var path: NavigationPath
    var openDownloads: () -> Void = {}

    @Environment(\.session) private var session
    @Environment(AccountStore.self) private var accounts
    @Environment(ServerReachability.self) private var reachability
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @Environment(\.scenePhase) private var scenePhase
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(WatchHistory.self) private var history
    #endif
    @State private var feed = HomeFeed()
    /// The featured title the banner shows, kept here so it stays as the banner scrolls out of
    /// the page and back, and as the titles load again.
    @State private var featuredId: String?
    /// Home is the tab on screen.
    @State private var isOnScreen = false
    @State private var isScrolling = false
    #if os(iOS) || os(visionOS)
    @State private var showingSettings = false
    #endif
    #if !os(tvOS)
    @Environment(SoundPlayer.self) private var sounds
    @State private var showingSounds = false
    #endif
    #if os(iOS)
    @Environment(TVRemote.self) private var tvRemote
    @State private var showingRemote = false
    #elseif os(macOS)
    @Environment(\.openWindow) private var openWindow
    #elseif os(tvOS)
    /// Where the banner and the rows are, for holding the focused one in place.
    @State private var rowLayout = RowPageLayout()
    /// Focus is on Home, not on the sidebar over it.
    @FocusedValue(\.isInHome) private var focusIsInHome
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            EdgeToEdgeScrollView(underTopBars: hasBanner) {
                LazyVStack(alignment: .leading, spacing: 34) {
                    Group {
                        if !feed.featured.isEmpty {
                            HeroBanner(items: feed.featured, shownId: $featuredId, mayTurn: bannerMayTurn, feed: feed) { path.append($0) }
                        } else if feed.isLoadingFirstTime {
                            HeroPlaceholder()
                        }
                    }
                    #if os(tvOS)
                    .pageRow("hero", in: rowLayout)
                    #endif
                    Group {
                        if feed.sessionEnded {
                            sessionEndedNotice
                        } else if let loadError = feed.loadError, !feed.isOffline {
                            failureNotice(loadError)
                        }
                    }
                    #if os(tvOS)
                    .pageRow("notice", in: rowLayout, holding: .whole)
                    #endif
                    #if !os(tvOS)
                    if feed.isOffline, !downloadedTitles.isEmpty {
                        downloadsRow
                    }
                    #endif
                    ForEach(feed.rows) { row in
                        HomeRowView(row: row, titles: feed.items[row.id], problem: feed.isOffline ? nil : feed.problems[row.id],
                                    isShown: feed.isShown(row.id), isTruncated: feed.truncated.contains(row.id), feed: feed) {
                            feed.removeFromContinueWatching($0) { messages.show($0) }
                        }
                        #if os(tvOS)
                        // The first row under the banner leaves what fits of it in view.
                        .pageRow(row.id, in: rowLayout, holding: row.id == leadRow ? .whole : .top)
                        #endif
                    }
                }
                #if os(tvOS)
                .rowPageContent(rowLayout)
                .focusedValue(\.isInHome, true)
                #endif
                .padding(.bottom, Metrics.edge)
            }
            #if os(tvOS)
            .rowPage(rowLayout)
            #endif
            .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
            // On Apple TV, focus moves into Home at launch, and with nothing focusable there the
            // remote would do nothing at all; Check Again takes it.
            .overlay {
                if feed.hasNoTitles {
                    noTitles
                } else if showsNothingOffline {
                    nothingOffline
                }
            }
            .overlay(alignment: .bottom) {
                if let removal = feed.removal {
                    RemovalToast(removal: removal) { undo(removal) } expire: { feed.settleRemoval(removal) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: feed.removal?.id)
            #if os(tvOS)
            // Undo, while the toast says so; the card the press was meant for is gone.
            .onPlayPauseCommand(perform: feed.removal.map { removal in { undo(removal) } })
            #endif
            .pageBackground()
            .screenTitle("Home")
            .onAppear { isOnScreen = true }
            .onDisappear {
                isOnScreen = false
                feed.wentAway()
                saveForNextTime()
            }
            #if os(tvOS)
            .toolbarVisibility(hasBanner ? .hidden : .automatic, for: .navigationBar)
            #elseif os(iOS) || os(visionOS)
            // Over the banner the bar keeps only its buttons (Remote on iPhone and iPad, once a
            // TV has been found, Sounds and Settings), floating on the artwork, and once it's
            // scrolled away a small title; on iPhone Duo they go in the vertical bar with the
            // rest of the bar's buttons.
            .navigationBarTitleDisplayMode(hasBanner ? .inline : .automatic)
            .heroScrollEdge()
            .toolbar {
                #if os(iOS)
                if tvRemote.hasFoundTV {
                    ToolbarItem(placement: .barTrailing) { remoteButton }
                }
                #endif
                ToolbarItem(placement: .barTrailing) { soundsButton }
                ToolbarItem(placement: .barTrailing) { settingsButton }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    #if os(iOS)
                    // A big iPad's Settings as a page rather than a small card.
                    .presentationSizing(.page)
                    #endif
            }
            #if os(iOS)
            .sheet(isPresented: $showingRemote) { TVRemoteScreen() }
            .task(id: session?.account) { await tvRemote.lookForTV() }
            #endif
            #elseif os(macOS)
            .toolbar {
                ToolbarItem(placement: .barTrailing) { portableTVButton }
                ToolbarItem(placement: .barTrailing) { soundsButton }
                ToolbarItem(placement: .barTrailing) { AccountMenu() }
            }
            #endif
            #if !os(tvOS)
            .sheet(isPresented: $showingSounds) { SoundsView() }
            #endif
            .itemDestinations()
            // Out of reach, a pull asks the server again, and Home loads once it answers.
            .refreshable {
                if reachability.isOutOfReach {
                    await reachability.check()
                } else {
                    await load(reshuffling: true)
                }
            }
            // Again when the server goes out of reach, to stop asking it and show what's saved,
            // and when it answers again.
            .task(id: reachability.isOutOfReach) { await load() }
            // Back from the background, Home refreshes as on coming back to it.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    feed.wentAway()
                    saveForNextTime()
                }
                if phase == .active, isOnScreen { Task { await load() } }
            }
            // A playback started here, from the banner or a card, moved Continue Watching.
            .onChange(of: player.endedPlayback) {
                feed.apply(player.endedPlayback)
                Task { await load() }
            }
            .onChange(of: feed.featured.map(\.id)) { old, new in
                featuredId = FeaturedRotation.id(keeping: featuredId, from: old, in: new)
            }
        }
        .opensTitles(on: $path)
    }

    /// The banner shows, or until Home's first load comes back, its place does, so the page keeps
    /// one shape and one kind of title from its first frame.
    private var hasBanner: Bool {
        !feed.featured.isEmpty || feed.isLoadingFirstTime
    }

    /// Home is on screen, with nothing over it and not scrolling, so the banner turning can't
    /// change a title under the viewer's hand or behind their back. On Apple TV, that's with
    /// focus on Home, not on the sidebar over it.
    private var bannerMayTurn: Bool {
        var covered = !path.isEmpty || player.coversScreens || isScrolling
        #if os(iOS) || os(visionOS)
        covered = covered || showingSettings
        #endif
        #if !os(tvOS)
        covered = covered || showingSounds
        #endif
        #if os(iOS)
        covered = covered || showingRemote
        #endif
        #if os(tvOS)
        covered = covered || focusIsInHome != true
        #endif
        return isOnScreen && scenePhase == .active && !covered
    }

    #if os(tvOS)
    /// The first row that shows, the one under the banner.
    private var leadRow: HomeRow.ID? {
        feed.rows.first { feed.isShown($0.id) }?.id
    }
    #endif

    #if !os(tvOS)
    /// Moves while a sound plays.
    private var soundsButton: some View {
        Button("Sounds", systemImage: "waveform") { showingSounds = true }
            .symbolEffect(.variableColor.iterative, isActive: sounds.state == .playing && !sounds.isSteppedAside)
            .help("Sounds")
            .accessibilityIdentifier("home.sounds")
    }
    #endif

    #if os(iOS)
    /// This iPhone or iPad as the remote of a Mac showing Portable TV.
    private var remoteButton: some View {
        Button("Remote", systemImage: "appletvremote.gen4") { showingRemote = true }
            .accessibilityIdentifier("home.remote")
    }
    #elseif os(macOS)
    /// This Mac as an Apple TV, on the TV it's plugged into.
    private var portableTVButton: some View {
        Button("Portable TV", systemImage: "tv") { openWindow(id: PortableTVWindow.id) }
            .help("Use this Mac as a TV, with your iPhone as the remote")
            .accessibilityIdentifier("home.portableTV")
    }
    #endif

    #if os(iOS) || os(visionOS)
    /// The avatar: who's signed in, switching to another sign-in, adding one, and Settings where
    /// it isn't a tab of its own.
    private var settingsButton: some View {
        AccountMenu(openSettings: MainTabs.hasSettingsTab ? nil : { showingSettings = true })
    }
    #endif

    private var sessionEndedNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Signed Out of \(session?.account.serverName ?? "the Server")", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text("The server no longer accepts this sign-in, for example after a password change or a server reset. Downloads still play.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AdaptiveStack {
                Button("Sign In Again") { accounts.signOut() }
                    .accessibilityIdentifier("home.signInAgain")
                #if !os(tvOS)
                Button("Watch Downloads", action: openDownloads)
                #endif
            }
            .buttonStyle(.platformGlass)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .padding(.horizontal, Metrics.edge)
    }

    /// Why Home couldn't load: the server out of reach, or failing.
    private func failureNotice(_ message: String) -> some View {
        LoadFailureNotice(failure: LoadFailure("Couldn't Load Home", message: message)) {
            Task { await load() }
        } more: {
            #if !os(tvOS)
            Button("Watch Downloads", action: openDownloads)
            #endif
        }
        .padding(.horizontal, Metrics.edge)
    }

    private var noTitles: some View {
        ContentUnavailableView {
            Label("No Movies or Shows Yet", systemImage: "film.stack")
        } description: {
            Text("\(session?.account.serverName ?? "The server") has no movies or shows for you. Add some in Jellyfin, then check again.")
        } actions: {
            Button("Check Again") { Task { await load() } }
                .buttonStyle(.platformGlassProminent)
                .accessibilityIdentifier("home.checkAgain")
        }
    }

    private func undo(_ removal: ContinueWatchingRemoval) {
        feed.undo(removal) { messages.show($0) }
    }

    private func load(reshuffling: Bool = false) async {
        guard let session else { return }
        await feed.load(session: session, isServerOutOfReach: reachability.isOutOfReach, reshuffling: reshuffling)
        // Asks whether the server's there at all, rather than say only that Home didn't load.
        if feed.loadError != nil { await reachability.check() }
    }

    /// Saves Home for the next time it opens, while still signed in where it's from: one going
    /// away as its sign-in ends has been deleted, and stays so.
    private func saveForNextTime() {
        guard let session, accounts.account?.isSame(as: session.account) == true else { return }
        feed.saveForNextTime()
    }

    /// Offline with nothing saved of Home, and nothing downloaded to show in its place.
    private var showsNothingOffline: Bool {
        #if os(tvOS)
        feed.isOffline && feed.featured.isEmpty && !feed.rows.contains { feed.isShown($0.id) }
        #else
        feed.isOffline && feed.featured.isEmpty && !feed.rows.contains { feed.isShown($0.id) } && downloadedTitles.isEmpty
        #endif
    }

    /// Why Home is empty: the server out of reach before Home was ever saved.
    private var nothingOffline: some View {
        ContentUnavailableView {
            Label("Can't Reach \(session?.account.serverTitle ?? "the Server")", systemImage: "wifi.slash")
        } description: {
            if case .outOfReach(let absence) = reachability.state {
                Text(absence.explanation(server: session?.account.serverTitle ?? "The server"))
            }
        } actions: {
            Button("Try Again") { Task { await reachability.check() } }
                .buttonStyle(.platformGlassProminent)
                .disabled(reachability.isChecking)
                .accessibilityIdentifier("home.offlineRetry")
        }
    }

    #if !os(tvOS)
    /// What's downloaded for the sign-in, for the row that leads Home offline.
    private var downloadedTitles: [JellyfinItem] {
        OfflineDownloads.titles(downloads.jobs, of: session?.account) { history.entry(for: $0) }
    }

    /// The sign-in's downloads, which play on a tap, first on Home while the server is out of reach.
    private var downloadsRow: some View {
        Shelf(title: "Downloads", items: downloadedTitles, cardWidth: Metrics.landscapeWidth, placeholderStyle: .landscape) { item in
            DownloadedCard(item: item)
        }
    }
    #endif
}

extension FocusedValues {
    /// Set while focus is on Home's banner or rows.
    @Entry var isInHome: Bool?
}

/// One of Home's rows: its cards once they're in, their shapes until then, or why they couldn't
/// load. A row with nothing in it isn't there at all. The row is the same `Shelf` loading and
/// loaded, so on Apple TV focus on a stand-in card stays in the row as the cards come in. It's
/// given its titles rather than reading them from the feed, so one row loading leaves the others
/// as they are.
private struct HomeRowView: View {
    let row: HomeRow
    /// Nil while they load.
    let titles: [JellyfinItem]?
    let problem: String?
    let isShown: Bool
    /// The row holds only some of its list's titles, so its title opens the rest.
    let isTruncated: Bool
    let feed: HomeFeed
    let removeFromContinueWatching: (JellyfinItem) -> Void
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        Group {
            if let problem {
                problemRow(problem)
            } else if isShown {
                Shelf(title: row.list.title, seeAll: isTruncated ? row.list : nil, items: titles, cardWidth: row.list.style.cardWidth,
                      placeholderStyle: row.list.style) { item in
                    card(item)
                }
            }
        }
        .onAppear { feed.rowAppeared(row.id) }
        .onDisappear { feed.rowDisappeared(row.id) }
    }

    @ViewBuilder private func card(_ item: JellyfinItem) -> some View {
        if row.id == HomeRows.continueWatching.id {
            // Picks up where it was left, as the widget does; the title's page is in the menu.
            Button { player.play(.item(item)) } label: { LandscapeCard(item: item, playsOnTap: true) }
                .buttonStyle(.artwork)
                .titleMenu(item, playsOnTap: true) { feed.replace($0) } more: {
                    Button("Remove from Continue Watching", systemImage: "minus.circle") { removeFromContinueWatching(item) }
                }
                .accessibilityHint(item.resumeSeconds != nil ? "Resumes it" : "Plays it")
                .playableOffline(item, dimming: true)
        } else {
            switch row.list.style {
            case .poster:
                NavigationLink(value: item) { PosterCard(item: item) }
                    .buttonStyle(.artwork)
                    .titleMenu(item) { feed.replace($0) }
            case .landscape:
                NavigationLink(value: item) { LandscapeCard(item: item) }
                    .buttonStyle(.artwork)
                    .titleMenu(item) { feed.replace($0) }
            }
        }
    }

    private func problemRow(_ problem: String) -> some View {
        LoadFailureNotice(LoadFailure("Couldn't Load \(row.list.title)", message: problem)) { feed.retry(row.id) }
            .padding(.horizontal, Metrics.edge)
    }
}

/// Says a title left Continue Watching, and offers to put it back for a few seconds; on Apple
/// TV, with the Play/Pause button, as the card it came from is gone.
private struct RemovalToast: View {
    let removal: ContinueWatchingRemoval
    let undo: () -> Void
    /// The time to put it back is over.
    let expire: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// How long the toast stays; long enough to reach Undo with VoiceOver too.
    private var duration: Duration { .seconds(voiceOverEnabled ? 15 : 6) }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Removed from Continue Watching").font(.subheadline.weight(.semibold))
                Text(removal.item.titleName).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            #if os(tvOS)
            Label("Undo", systemImage: "playpause.fill")
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel("Play/Pause to undo")
            #else
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.platformGlass)
                .accessibilityIdentifier("home.undoRemove")
            #endif
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .padding(.horizontal, Metrics.edge)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .task(id: removal.id) {
            AccessibilityNotification.Announcement("Removed \(removal.item.titleName) from Continue Watching").post()
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            expire()
        }
    }
}

/// Which featured title the banner shows, kept as the title's id, so the banner stays on it when
/// the titles load again in another order. Off Apple TV the banner pages through them, with the
/// last one again before the first and the first again after the last, so a swipe or a turn goes
/// round from the end to the start without running back across them all.
nonisolated enum FeaturedRotation {
    /// Where the title `id` is in `items`, or the first when it's gone.
    static func position(of id: String?, in items: [JellyfinItem]) -> Int {
        items.firstIndex { $0.id == id } ?? 0
    }

    /// The title `step` on from the title `id` in `items`, round from the end to the start.
    static func id(after id: String?, by step: Int, in items: [JellyfinItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let count = items.count
        return items[((position(of: id, in: items) + step) % count + count) % count].id
    }

    /// The title to show once the titles `old` became `new`: `id` while it's still there, else
    /// the first after it that is, round from the end.
    static func id(keeping id: String?, from old: [String], in new: [String]) -> String? {
        guard let id, !new.contains(id) else { return id }
        guard let start = old.firstIndex(of: id) else { return new.first }
        let after = old[(start + 1)...] + old[..<start]
        return after.first(where: new.contains) ?? new.first
    }

    /// How many pages `count` titles take.
    static func pageCount(for count: Int) -> Int {
        count > 1 ? count + 2 : count
    }

    /// The title at `page`, among `count`.
    static func title(atPage page: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return ((page - 1) % count + count) % count
    }

    /// The page of the title at `position`, among `count`: its own, not a copy at an end.
    static func page(ofTitle position: Int, count: Int) -> Int {
        count > 1 ? position + 1 : 0
    }
}

/// How far the banner's pages have scrolled, as a page and a share of the next, and how wide its
/// words are: read by the words alone, which follow the pictures as they move.
@MainActor @Observable
private final class HeroPager {
    var progress: Double = 0
    var isPaging = false
    var wordsWidth: CGFloat = 0
}

/// The featured titles, one at a time across the top, turning every few seconds, the active dot
/// filling as the next turn comes. It holds still while anything might act on the title it shows:
/// a finger or pointer on it, one of its buttons with focus, a scroll, a menu or sheet over Home,
/// a page over Home or another tab, the player, Apple TV's sidebar, and Reduce Motion, VoiceOver
/// or Switch Control, which would have it change under them too. Turning on its own, it waits for
/// the next title's picture and logo, so the one shown stays until they're in.
///
/// It turns by hand too. On iPhone, iPad, the Mac and Vision Pro the pictures follow a swipe and
/// the words follow them, a tap on the picture opens the title, a dot goes to its title, and on
/// the Mac and with an iPad's pointer, arrows at the sides show under the pointer; on the Mac the
/// arrow keys turn it while one of its buttons has focus. On Apple TV, right from its last button
/// goes on, and left from its first goes back but for the first title, where it opens the
/// sidebar, the titles fading from one to the next with focus kept on the button.
private struct HeroBanner: View {
    let items: [JellyfinItem]
    @Binding var shownId: String?
    /// Home is on screen with nothing over it, and not scrolling.
    let mayTurn: Bool
    let feed: HomeFeed
    let openDetails: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.topBarsHeight) private var topBarsHeight
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A finger is down on the banner.
    @GestureState private var isTouched = false
    @State private var isHovered = false
    #if os(macOS)
    @State private var isMenuOpen = false
    #endif
    /// When the title last changed: Play or Details pressed right after was meant for the one before.
    @State private var turnedAt = ContinuousClock.now - .seconds(1)
    /// When the title shown began counting down to the next; nil while the banner holds still.
    @State private var countdownStart: Date?
    @State private var visibleHeight: CGFloat = 0
    @State private var prefetcher = ImagePrefetcher()
    @State private var presentations = PresentationProbe()
    @FocusState private var focusedButton: HeroButton?
    #if os(tvOS)
    /// Bounds the banner's default focus, so it's the banner's to take when focus comes in.
    @Namespace private var focusScope
    @FocusState private var isGoingBack: Bool
    #else
    @State private var pager = HeroPager()
    /// The page the pictures are on.
    @State private var page: Int?
    #endif

    /// How long each title shows, turning on its own.
    private static let interval: TimeInterval = 8

    private enum HeroButton {
        case play, details
    }

    /// What decides when the banner turns on its own: it counts down afresh each time it changes.
    private struct Turning: Equatable {
        let ids: [String]
        let shownId: String?
        let holds: Bool
    }

    var body: some View {
        let position = FeaturedRotation.position(of: shownId, in: items)
        let item = items[position]
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                #if os(tvOS)
                turning(item, alignment: .bottomLeading) {
                    heading(item)
                    if !isStacked { about(item) }
                }
                if !isStacked { buttons(item) }
                #else
                // Laid out for the title shown, and drawn for the pages as they move.
                words(item)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pager.wordsWidth = $0 }
                    .overlay(alignment: .bottomLeading) {
                        PagedWords(pager: pager, items: items) { words($0) }
                    }
                #endif
                if !isStacked { dots(position) }
            }
            // The words go on the dark of the fade in either appearance.
            .environment(\.colorScheme, .dark)
            .heroWords()
            .padding(.horizontal, Metrics.edge)
            .padding(.bottom, 6 + HeroBackdrop.blendHeight(in: colorScheme))
            // Taller than the artwork's height when the words need it, so none of them is
            // squeezed, or goes under the bars over the page's top.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, topBarsHeight > 0 ? topBarsHeight + 14 : 0)
            .frame(maxWidth: .infinity, minHeight: HeroBackdrop.height(fullHeight, visible: visibleHeight), alignment: .bottomLeading)
            .background { art(item) }
            #if !os(tvOS)
            .overlay { arrows }
            .animation(.easeOut(duration: 0.2), value: isHovered)
            #endif
            if isStacked {
                VStack(alignment: .leading, spacing: 10) {
                    #if os(tvOS)
                    turning(item, alignment: .topLeading) { about(item) }
                    #else
                    about(item)
                    #endif
                    buttons(item)
                    dots(position)
                }
                .padding(.horizontal, Metrics.edge)
                .padding(.bottom, 6)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.bounds(of: .scrollView)?.height ?? 0 } action: { visibleHeight = $0 }
        .background { PresentationProbeView(probe: presentations) }
        #if os(iOS)
        // Alongside the swipe and the buttons, not ahead of them.
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isTouched) { _, touched, _ in touched = true })
        #endif
        #if !os(tvOS)
        .onHover { isHovered = $0 }
        #endif
        #if os(macOS)
        .onMoveCommand { direction in
            switch direction {
            case .left: turn(by: -1)
            case .right: turn(by: 1)
            default: break
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSMenu.didBeginTrackingNotification) { isMenuOpen = true }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSMenu.didEndTrackingNotification) { isMenuOpen = false }
        }
        #endif
        #if os(tvOS)
        .focusSection()
        .focusScope(focusScope)
        // Up from the rows, focus goes to the title's main button, not whichever is above the
        // card it leaves.
        .defaultFocus($focusedButton, focusesPlay(item) ? .play : .details, priority: .userInitiated)
        #else
        .onChange(of: shownId) { showPage(of: shownId) }
        .onChange(of: items.map(\.id)) { showPage(of: shownId) }
        .onAppear { showPage(of: shownId) }
        #endif
        .task(id: items.map(\.id)) {
            prefetcher.startPrefetching(with: items.flatMap(imageURLs))
        }
        .task(id: Turning(ids: items.map(\.id), shownId: shownId, holds: holds)) {
            guard !holds, items.count > 1 else {
                countdownStart = nil
                return
            }
            countdownStart = .now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard !Task.isCancelled else { return }
                guard !presentations.isCovered else {
                    countdownStart = .now
                    continue
                }
                let shown = shownId
                guard let next = items.first(where: { $0.id == FeaturedRotation.id(after: shown, by: 1, in: items) }) else { return }
                await load(next)
                guard !Task.isCancelled, !presentations.isCovered, shownId == shown else { continue }
                turn(by: 1)
                return
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.hero")
    }

    /// At the accessibility sizes, all but the title go under the picture rather than over it,
    /// where they would run up past the fade into the page, onto the picture itself.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    // MARK: Pictures

    #if os(tvOS)
    /// The title's picture, fading into the next one's.
    private func art(_ item: JellyfinItem) -> some View {
        ZStack {
            HeroBackdrop(url: session?.backdrop(item), from: 0.3, middle: 0.7, at: 0.72)
                .id(item.id)
                .transition(.opacity)
        }
    }
    #else
    /// The titles' pictures, side by side, a page each the screen's width, which a swipe moves
    /// and a tap on opens.
    private func art(_ item: JellyfinItem) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(0..<FeaturedRotation.pageCount(for: items.count), id: \.self) { page in
                    let title = items[FeaturedRotation.title(atPage: page, count: items.count)]
                    HeroBackdrop(url: session?.backdrop(title), from: 0.3, middle: 0.7, at: 0.72)
                        .containerRelativeFrame(.horizontal)
                        .contentShape(.rect)
                        .onTapGesture {
                            guard !justTurned else { return }
                            openDetails(title)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .scrollDisabled(items.count < 2)
        // Past the safe area at the sides, under any bars there, as the page's artwork runs.
        .ignoresSafeArea(edges: .horizontal)
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.containerSize.width > 0 ? geometry.contentOffset.x / geometry.containerSize.width : 0
        } action: { _, progress in
            pager.progress = progress
        }
        .onScrollPhaseChange { _, phase in
            pager.isPaging = phase != .idle
            if phase == .idle { settlePage() }
        }
        .visualEffect { content, geometry in
            // Pulled down past the top, the pictures stretch up from their foot to fill the space.
            let overscroll = max(0, geometry.frame(in: .scrollView(axis: .vertical)).minY)
            return content.scaleEffect(geometry.size.height > 0 ? 1 + overscroll / geometry.size.height : 1, anchor: .bottom)
        }
        .accessibilityHidden(true)
    }

    /// Arrows at the sides, under a pointer, that turn the titles.
    @ViewBuilder private var arrows: some View {
        if items.count > 1, isHovered {
            HStack {
                arrow("Previous Title", systemImage: "chevron.left") { turn(by: -1) }
                Spacer()
                arrow("Next Title", systemImage: "chevron.right") { turn(by: 1) }
            }
            .padding(.horizontal, Metrics.edge / 2)
            .transition(.opacity)
        }
    }

    private func arrow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.platformGlass)
        .buttonBorderShape(.circle)
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .help(title)
        #endif
        // The dots turn the titles for VoiceOver, Voice Control and Switch Control.
        .accessibilityHidden(true)
    }

    /// Scrolls the pictures to the title `id`'s page, at once, when they're on another title's.
    private func showPage(of id: String?) {
        let position = FeaturedRotation.position(of: id, in: items)
        if let page, FeaturedRotation.title(atPage: page, count: items.count) == position { return }
        let target = FeaturedRotation.page(ofTitle: position, count: items.count)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { page = target }
        pager.progress = Double(target)
    }

    /// The pictures came to rest: the banner shows the title they're on, and from a copy at an
    /// end, they go to the title's own page, which looks the same.
    private func settlePage() {
        guard let page else { return }
        let position = FeaturedRotation.title(atPage: page, count: items.count)
        let own = FeaturedRotation.page(ofTitle: position, count: items.count)
        if own != page {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.page = own }
        }
        pager.progress = Double(own)
        let id = items[position].id
        if id != shownId {
            turnedAt = .now
            shownId = id
        }
    }
    #endif

    // MARK: Words

    /// `content` for `item`, giving way to the next title's as a whole: the words going fade out
    /// quickly, then the new ones fade in, sliding a little into place.
    private func turning(_ item: JellyfinItem, alignment: Alignment, @ViewBuilder content: () -> some View) -> some View {
        let arrival: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 16))
        return ZStack(alignment: alignment) {
            VStack(alignment: .leading, spacing: 10) { content() }
                .id(item.id)
                .transition(.asymmetric(insertion: arrival.animation(.easeOut(duration: 0.3).delay(0.15)),
                                        removal: .opacity.animation(.easeIn(duration: 0.15))))
        }
    }

    /// A page's words over its picture: the title, and but at the accessibility sizes, the
    /// facts, the overview and the buttons.
    private func words(_ item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(item)
            if !isStacked {
                about(item)
                buttons(item)
            }
        }
    }

    /// The title, as its logo when there is one. A tap on it goes to the picture under it.
    private func heading(_ item: JellyfinItem) -> some View {
        TitleLogo(url: session?.logo(item, width: TitleLogo.requestWidth), name: item.name)
            .accessibilityAddTraits(.isHeader)
            .allowsHitTesting(false)
    }

    /// The facts and the overview.
    @ViewBuilder private func about(_ item: JellyfinItem) -> some View {
        Group {
            FactsLine(item: item)
            if let overview = item.overview {
                Text(overview).font(.subheadline).lineLimit(dynamicTypeSize.lineLimit(2)).frame(maxWidth: 640, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    /// Play and Details: side by side, with Details as its symbol alone when "Resume · 1 hr, 10
    /// min left" leaves no room for its name, or one above the other.
    @ViewBuilder private func buttons(_ item: JellyfinItem) -> some View {
        let choices = ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playButton(item, oneLine: true)
                detailsButton(item, titled: true)
            }
            HStack(spacing: 12) {
                playButton(item, oneLine: true)
                detailsButton(item, titled: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                playButton(item, oneLine: false)
                detailsButton(item, titled: true)
            }
        }
        .controlSize(.large)
        #if os(tvOS)
        // A move command only reaches the banner when focus has nowhere to go, as right from
        // Details does. Left from the first button focus would go out to the sidebar, so while
        // there's a title before, a stop in the margin left of the buttons takes it and goes back
        // a title. It's laid out there, not offset there: focus goes by where views are laid out.
        HStack(spacing: Metrics.edge / 4) {
            Color.clear
                .frame(width: Metrics.edge / 2)
                .focusable(FeaturedRotation.position(of: shownId, in: items) > 0)
                .focused($isGoingBack)
                .accessibilityHidden(true)
            choices
        }
        .padding(.leading, -Metrics.edge * 3 / 4)
        .onChange(of: isGoingBack) { _, going in
            guard going else { return }
            let previous = items[FeaturedRotation.position(of: FeaturedRotation.id(after: shownId, by: -1, in: items), in: items)]
            focusedButton = focusesPlay(previous) ? .play : .details
            turn(by: -1)
        }
        .onMoveCommand { direction in
            if direction == .right, focusedButton == .details { turn(by: 1) }
        }
        #else
        choices
        #endif
    }

    /// Whether the banner offers to play the title: a movie that's out, or a show's next episode.
    private func showsPlay(for item: JellyfinItem) -> Bool {
        item.isSeries || (item.isPlayable && !item.isNotYetAvailable())
    }

    /// What Play plays: the title, or for a show its next episode, once that's known.
    private func playing(_ item: JellyfinItem) -> JellyfinItem {
        item.isSeries ? feed.featuredEpisodes[item.id] ?? item : item
    }

    #if os(tvOS)
    /// Whether focus goes to Play: shown, and not off with the server out of reach, as Apple TV
    /// has no downloads.
    private func focusesPlay(_ item: JellyfinItem) -> Bool {
        showsPlay(for: item) && !reachability.isOutOfReach
    }
    #endif

    @ViewBuilder private func playButton(_ item: JellyfinItem, oneLine: Bool) -> some View {
        if showsPlay(for: item) {
            Button {
                guard !justTurned else { return }
                play(item)
            } label: {
                Label(playLabel(for: item), systemImage: "play.fill")
            }
            .buttonStyle(.platformGlassProminent)
            .fixedSize(horizontal: oneLine, vertical: false)
            .accessibilityLabel(spokenPlayLabel(for: item))
            .playableOffline(playing(item))
            .focused($focusedButton, equals: .play)
        }
    }

    private func detailsButton(_ item: JellyfinItem, titled: Bool) -> some View {
        Button {
            guard !justTurned else { return }
            openDetails(item)
        } label: {
            if titled {
                Label("Details", systemImage: "info.circle")
            } else {
                Label("Details", systemImage: "info.circle").labelStyle(.iconOnly).help("Details")
            }
        }
        .buttonStyle(.platformGlass)
        .fixedSize(horizontal: titled, vertical: false)
        .focused($focusedButton, equals: .details)
    }

    /// Plays a movie, or a show's next episode; a show with none to play opens instead.
    private func play(_ item: JellyfinItem) {
        guard item.isSeries else {
            player.play(.item(item))
            return
        }
        Task {
            if let episode = await feed.episode(for: item) {
                player.play(.item(episode))
            } else {
                openDetails(item)
            }
        }
    }

    /// "Resume · 1 hr, 10 min left", as the title's page has it, "Play S1, E1" for a show's next
    /// episode, "Play Again" for a movie watched, or "Play".
    private func playLabel(for item: JellyfinItem) -> String {
        if item.isSeries {
            return feed.featuredEpisodes[item.id].flatMap(LandscapeCard.shortCode).map { "Play \($0)" } ?? "Play"
        }
        if item.isPlayed { return "Play Again" }
        guard let resume = item.resumeSeconds else { return "Play" }
        guard let total = item.runtimeSeconds, total > resume else { return "Resume" }
        return "Resume · \(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
    }

    /// `playLabel(for:)` as it's said: "Resume, 1 hour, 10 minutes left", "Play Season 1, Episode 1".
    private func spokenPlayLabel(for item: JellyfinItem) -> String {
        if item.isSeries {
            return feed.featuredEpisodes[item.id]?.spokenEpisodeCode.map { "Play \($0)" } ?? "Play"
        }
        if item.isPlayed { return "Play Again" }
        guard let resume = item.resumeSeconds else { return "Play" }
        guard let total = item.runtimeSeconds, total > resume else { return "Resume" }
        return "Resume, \(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .wide))) left"
    }

    // MARK: Dots

    /// A dot for each title, the one shown long, filling as the next turn comes; a dot goes to
    /// its title.
    @ViewBuilder private func dots(_ position: Int) -> some View {
        if items.count > 1 {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: countdownStart == nil)) { context in
                let fill = countdownStart.map { min(1, max(0, context.date.timeIntervalSince($0) / Self.interval)) } ?? 1
                HStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        dot(isShown: index == position, fill: fill)
                            // A touch target's height around dots 6 points high, taken back out of
                            // the layout below so nothing around them moves.
                            .frame(width: (index == position ? 18 : 6) + 6, height: 44)
                            .contentShape(.rect)
                            .onTapGesture { go(to: index) }
                    }
                }
            }
            .padding(.horizontal, -3)
            // Turns the titles for VoiceOver, with a swipe up or down, and for Voice
            // Control and Switch Control, with its actions.
            .accessibilityElement()
            .accessibilityLabel("Featured Titles")
            .accessibilityValue("\(position + 1) of \(items.count)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: turn(by: 1)
                case .decrement: turn(by: -1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Next Title") { turn(by: 1) }
            .accessibilityAction(named: "Previous Title") { turn(by: -1) }
            .accessibilityIdentifier("home.heroPages")
            .padding(.vertical, -19)
        }
    }

    private func dot(isShown: Bool, fill: Double) -> some View {
        Capsule().fill(.tertiary)
            .overlay(alignment: .leading) {
                if isShown {
                    Rectangle().fill(.primary).frame(width: 18 * fill)
                }
            }
            .clipShape(.capsule)
            .frame(width: isShown ? 18 : 6, height: 6)
            .animation(.snappy(duration: 0.25), value: isShown)
    }

    // MARK: Turning

    /// Something might act on the title shown, so it doesn't turn on its own.
    private var holds: Bool {
        var holds = !mayTurn || isTouched || isHovered || focusedButton != nil || holdsStill
        #if os(macOS)
        holds = holds || isMenuOpen
        #endif
        #if !os(tvOS)
        holds = holds || pager.isPaging
        #endif
        return holds
    }

    /// Reduce Motion asks for no motion that goes on by itself; VoiceOver and Switch Control move
    /// through the banner one piece at a time, and a title turning would change it under them.
    private var holdsStill: Bool {
        reduceMotion || voiceOverEnabled || switchControlEnabled
    }

    /// The title changed a moment ago, too soon for a press to be meant for the new one.
    private var justTurned: Bool {
        turnedAt.duration(to: .now) < .milliseconds(400)
    }

    private func turn(by step: Int) {
        guard items.count > 1 else { return }
        #if os(tvOS)
        show(FeaturedRotation.id(after: shownId, by: step, in: items))
        #else
        let position = FeaturedRotation.position(of: shownId, in: items)
        scroll(toPage: FeaturedRotation.page(ofTitle: position, count: items.count) + step)
        #endif
    }

    private func go(to position: Int) {
        guard items.indices.contains(position) else { return }
        #if os(tvOS)
        show(items[position].id)
        #else
        scroll(toPage: FeaturedRotation.page(ofTitle: position, count: items.count))
        #endif
    }

    #if os(tvOS)
    private func show(_ id: String?) {
        turnedAt = .now
        withAnimation(.easeInOut(duration: 0.6)) { shownId = id }
    }
    #else
    /// Moves the pictures to `target`, sliding, or with Reduce Motion at once.
    private func scroll(toPage target: Int) {
        turnedAt = .now
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { page = target }
            settlePage()
        } else {
            withAnimation(.smooth(duration: 0.55)) { page = target } completion: { settlePage() }
        }
    }
    #endif

    /// The pictures the banner shows for `item`: its backdrop and logo.
    private func imageURLs(_ item: JellyfinItem) -> [URL] {
        [session?.backdrop(item), session?.logo(item, width: TitleLogo.requestWidth)].compactMap(\.self)
    }

    /// Waits for `item`'s pictures to be in, or to fail.
    private func load(_ item: JellyfinItem) async {
        await withTaskGroup(of: Void.self) { group in
            for url in imageURLs(item) {
                group.addTask { _ = try? await ImagePipeline.shared.image(for: url) }
            }
        }
    }

    private var fullHeight: CGFloat {
        #if os(tvOS)
        820
        #elseif os(iOS)
        sizeClass == .regular ? 580 : 500
        #else
        520
        #endif
    }
}

#if !os(tvOS)
/// The words of the banner's pages around where its pictures have scrolled to, each moving with
/// its picture, a page apart, and fading as it goes; at rest, the shown title's alone. It alone
/// reads how far the pictures have scrolled, so the rest of the banner stays as it is meanwhile.
private struct PagedWords<Words: View>: View {
    let pager: HeroPager
    let items: [JellyfinItem]
    @ViewBuilder let words: (JellyfinItem) -> Words

    var body: some View {
        let progress = pager.progress
        let lower = Int(progress.rounded(.down))
        ZStack(alignment: .bottomLeading) {
            ForEach([lower, lower + 1], id: \.self) { page in
                let distance = Double(page) - progress
                if abs(distance) < 0.999, items.count > 0 {
                    words(items[FeaturedRotation.title(atPage: page, count: items.count)])
                        .offset(x: distance * pager.wordsWidth)
                        .opacity(max(0, 1 - abs(distance) * 1.4))
                }
            }
        }
    }
}
#endif

/// The banner's place while Home loads for the first time, as tall as the banner will be, so the
/// page doesn't change shape when it comes.
private struct HeroPlaceholder: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var visibleHeight: CGFloat = 0

    var body: some View {
        // Where the banner's words will be.
        Color.clear
            .frame(height: 1)
            .heroWords()
            .padding(.bottom, HeroBackdrop.blendHeight(in: colorScheme))
            .frame(maxWidth: .infinity, minHeight: HeroBackdrop.height(fullHeight, visible: visibleHeight), alignment: .bottom)
            .background {
                HeroBackdrop(url: nil, placeholder: nil, from: 0.3, middle: 0.7, at: 0.72)
                    .background(.quaternary.opacity(0.5))
            }
            .onGeometryChange(for: CGFloat.self) { $0.bounds(of: .scrollView)?.height ?? 0 } action: { visibleHeight = $0 }
            .accessibilityHidden(true)
    }

    private var fullHeight: CGFloat {
        #if os(tvOS)
        820
        #elseif os(iOS)
        sizeClass == .regular ? 580 : 500
        #else
        520
        #endif
    }
}

/// Whether a menu or sheet is over the window a view is in: on iPhone, iPad, Apple TV and Vision
/// Pro, something presented over the window's root, as a long-press menu or a sheet is. The Mac's
/// menus say when they open and close instead.
@MainActor
private final class PresentationProbe {
    #if canImport(UIKit)
    fileprivate weak var view: UIView?
    #endif

    var isCovered: Bool {
        #if canImport(UIKit)
        guard let window = view?.window else { return false }
        return window.rootViewController?.presentedViewController != nil
        #else
        false
        #endif
    }
}

#if canImport(UIKit)
/// Gives a `PresentationProbe` a view in the banner's window.
private struct PresentationProbeView: UIViewRepresentable {
    let probe: PresentationProbe

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        probe.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        probe.view = view
    }
}
#else
private struct PresentationProbeView: View {
    let probe: PresentationProbe

    var body: some View { Color.clear }
}
#endif
