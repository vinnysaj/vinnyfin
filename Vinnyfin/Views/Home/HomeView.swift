import Nuke
import SwiftUI

/// What to watch next, and everything else to find: a featured banner, what's in progress and
/// new, then a long run of rows from what was watched and liked, the best and newest, collections
/// and every genre. Each row's title opens all of its titles.
struct HomeView: View {
    /// The pages open on top of Home: titles, and lists in full.
    @Binding var path: NavigationPath
    var openDownloads: () -> Void = {}

    @Environment(\.session) private var session
    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var showingRemote = false
    #elseif os(macOS)
    @Environment(\.openWindow) private var openWindow
    #elseif os(tvOS)
    /// Where the banner and the rows are, for holding the focused one in place.
    @State private var rowLayout = RowPageLayout()
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            EdgeToEdgeScrollView(underTopBars: hasBanner) {
                LazyVStack(alignment: .leading, spacing: 34) {
                    Group {
                        if !feed.featured.isEmpty {
                            HeroBanner(items: feed.featured, shownId: $featuredId, mayTurn: bannerMayTurn) { path.append($0) }
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
                        } else if let loadError = feed.loadError {
                            failureNotice(loadError)
                        }
                    }
                    #if os(tvOS)
                    .pageRow("notice", in: rowLayout, holding: .whole)
                    #endif
                    ForEach(feed.rows) { row in
                        HomeRowView(row: row, feed: feed)
                            #if os(tvOS)
                            // The first row under the banner leaves what fits of it in view.
                            .pageRow(row.id, in: rowLayout, holding: row.id == leadRow ? .whole : .top)
                            #endif
                    }
                }
                #if os(tvOS)
                .rowPageContent(rowLayout)
                #endif
                .padding(.bottom, Metrics.edge)
            }
            #if os(tvOS)
            .rowPage(rowLayout)
            #endif
            .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
            // On Apple TV, focus moves into Home at launch, and with nothing focusable there the
            // remote would do nothing at all; Check Again takes it.
            .overlay { if feed.hasNoTitles { noTitles } }
            .pageBackground()
            .screenTitle("Home")
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            #if os(tvOS)
            .toolbarVisibility(hasBanner ? .hidden : .automatic, for: .navigationBar)
            #elseif os(iOS) || os(visionOS)
            // Over the banner the bar keeps only its buttons (Remote on iPhone and iPad, Sounds and
            // Settings), floating on the artwork, and once it's scrolled away a small title; on
            // iPhone Duo they go in the vertical bar with the rest of the bar's buttons.
            .navigationBarTitleDisplayMode(hasBanner ? .inline : .automatic)
            .heroScrollEdge()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .barTrailing) { remoteButton }
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
            #endif
            #elseif os(macOS)
            .toolbar {
                ToolbarItem(placement: .barTrailing) { portableTVButton }
                ToolbarItem(placement: .barTrailing) { soundsButton }
            }
            #endif
            #if !os(tvOS)
            .sheet(isPresented: $showingSounds) { SoundsView() }
            #endif
            .itemDestinations()
            .refreshable { await load(reshuffling: true) }
            .task { await load() }
            // A playback started here, from the banner or a card's menu, moved Continue Watching.
            .onChange(of: player.endedPlayback) { Task { await load() } }
        }
        .opensTitles(on: $path)
    }

    /// The banner shows, or until Home's first load comes back, its place does, so the page keeps
    /// one shape and one kind of title from its first frame.
    private var hasBanner: Bool {
        !feed.featured.isEmpty || feed.isLoadingFirstTime
    }

    /// Home is on screen, with nothing over it and not scrolling, so the banner turning can't
    /// change a title under the viewer's hand or behind their back.
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
        return isOnScreen && scenePhase == .active && !covered
    }

    #if os(tvOS)
    /// The first row that shows, the one under the banner.
    private var leadRow: HomeRow.ID? {
        feed.rows.first { HomeRowView.isShown($0, in: feed) }?.id
    }
    #endif

    #if !os(tvOS)
    /// Moves while a sound plays.
    private var soundsButton: some View {
        Button("Sounds", systemImage: "waveform") { showingSounds = true }
            .symbolEffect(.variableColor.iterative, isActive: sounds.state == .playing && !sounds.isSteppedAside)
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
    private var settingsButton: some View {
        Button("Settings", systemImage: "person.crop.circle") { showingSettings = true }
            .accessibilityIdentifier("home.settings")
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
                Button("Sign In Again") { Task { await accounts.signOut() } }
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

    private func load(reshuffling: Bool = false) async {
        guard let session else { return }
        await feed.load(session: session, reshuffling: reshuffling)
    }
}

/// One of Home's rows: its cards once they're in, their shapes until then, or why they couldn't
/// load. A row with nothing in it isn't there at all. The row is the same `Shelf` loading and
/// loaded, so on Apple TV focus on a stand-in card stays in the row as the cards come in.
private struct HomeRowView: View {
    let row: HomeRow
    let feed: HomeFeed

    /// Whether a row shows at all: not once it has loaded with nothing in it.
    static func isShown(_ row: HomeRow, in feed: HomeFeed) -> Bool {
        feed.problems[row.id] != nil || feed.items[row.id]?.isEmpty != true
    }

    var body: some View {
        Group {
            if let problem = feed.problems[row.id] {
                problemRow(problem)
            } else if Self.isShown(row, in: feed) {
                Shelf(title: row.list.title, seeAll: row.list, items: feed.items[row.id], cardWidth: row.list.style.cardWidth,
                      placeholderStyle: row.list.style) { item in
                    card(item)
                }
            }
        }
        .onAppear { feed.rowAppeared(row.id) }
        .onDisappear { feed.rowDisappeared(row.id) }
    }

    @ViewBuilder private func card(_ item: JellyfinItem) -> some View {
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

    private func problemRow(_ problem: String) -> some View {
        LoadFailureNotice(LoadFailure("Couldn't Load \(row.list.title)", message: problem)) { feed.retry(row.id) }
            .padding(.horizontal, Metrics.edge)
    }
}

/// Which featured title the banner shows, kept as the title's id, so the banner stays on it when
/// the titles load again in another order.
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
}

/// The featured titles, one at a time across the top, turning every few seconds. It holds still
/// while anything might act on the title it shows: a finger or pointer on it, one of its buttons
/// with focus, a scroll, a menu or sheet over Home, a page over Home or another tab, the player,
/// and Reduce Motion, VoiceOver or Switch Control, which would have it change under them too;
/// there the titles turn by hand, with the adjustable dots. Turning on its own, it waits for the
/// next title's picture and logo, so the one shown stays until they're in.
private struct HeroBanner: View {
    let items: [JellyfinItem]
    @Binding var shownId: String?
    /// Home is on screen with nothing over it, and not scrolling.
    let mayTurn: Bool
    let openDetails: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
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
    @State private var visibleHeight: CGFloat = 0
    @State private var prefetcher = ImagePrefetcher()
    @State private var presentations = PresentationProbe()
    @FocusState private var focusedButton: HeroButton?
    #if os(tvOS)
    /// Bounds the banner's default focus, so it's the banner's to take when focus comes in.
    @Namespace private var focusScope
    #endif

    private enum HeroButton {
        case play, details
    }

    /// What decides when the banner turns on its own: it counts down afresh each time it changes.
    private struct Turning: Equatable {
        let ids: [String]
        let holds: Bool
    }

    var body: some View {
        let item = items[FeaturedRotation.position(of: shownId, in: items)]
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                turning(item, alignment: .bottomLeading) {
                    heading(item)
                    if !isStacked { details(item) }
                }
                if !isStacked { pages }
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
            .background {
                ZStack {
                    HeroBackdrop(url: session?.backdrop(item), from: 0.3, middle: 0.7, at: 0.72)
                        .id(item.id)
                        .transition(.opacity)
                }
            }
            if isStacked {
                VStack(alignment: .leading, spacing: 10) {
                    turning(item, alignment: .topLeading) { details(item) }
                    pages
                }
                .padding(.horizontal, Metrics.edge)
                .padding(.bottom, 6)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.bounds(of: .scrollView)?.height ?? 0 } action: { visibleHeight = $0 }
        .background { PresentationProbeView(probe: presentations) }
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -40 { turn(by: 1) }
                    if value.translation.width > 40 { turn(by: -1) }
                }
        )
        // Alongside the swipe and the buttons, not ahead of them.
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isTouched) { _, touched, _ in touched = true })
        #endif
        #if !os(tvOS)
        .onHover { isHovered = $0 }
        #endif
        #if os(macOS)
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
        .defaultFocus($focusedButton, Self.showsPlay(for: item) ? .play : .details, priority: .userInitiated)
        #endif
        .task(id: items.map(\.id)) {
            prefetcher.startPrefetching(with: items.flatMap(imageURLs))
        }
        .task(id: Turning(ids: items.map(\.id), holds: holds)) {
            guard !holds else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, !presentations.isCovered else { continue }
                let shown = shownId
                guard let next = items.first(where: { $0.id == FeaturedRotation.id(after: shown, by: 1, in: items) }) else { return }
                await load(next)
                guard !Task.isCancelled, !presentations.isCovered, shownId == shown else { continue }
                show(next.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.hero")
    }

    /// At the accessibility sizes, all but the title go under the picture rather than over it,
    /// where they would run up past the fade into the page, onto the picture itself.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

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

    /// The title, as its logo when there is one.
    private func heading(_ item: JellyfinItem) -> some View {
        TitleLogo(url: session?.logo(item, width: TitleLogo.requestWidth), name: item.name)
            .accessibilityAddTraits(.isHeader)
    }

    /// Whether the banner offers to play the title: one that plays, and is out.
    private static func showsPlay(for item: JellyfinItem) -> Bool {
        item.isPlayable && !item.isNotYetAvailable()
    }

    /// The facts, the overview and the buttons.
    @ViewBuilder private func details(_ item: JellyfinItem) -> some View {
        FactsLine(item: item)
        if let overview = item.overview {
            Text(overview).font(.subheadline).lineLimit(dynamicTypeSize.lineLimit(2)).frame(maxWidth: 640, alignment: .leading)
        }
        // Side by side, with Details as its symbol alone when "Resume · 1 hr, 10 min left"
        // leaves no room for its name, or one above the other.
        ViewThatFits(in: .horizontal) {
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
    }

    @ViewBuilder private func playButton(_ item: JellyfinItem, oneLine: Bool) -> some View {
        if Self.showsPlay(for: item) {
            Button {
                guard !justTurned else { return }
                player.play(.item(item))
            } label: {
                Label(Self.playLabel(for: item), systemImage: "play.fill")
            }
            .buttonStyle(.platformGlassProminent)
            .fixedSize(horizontal: oneLine, vertical: false)
            .accessibilityLabel(Self.spokenPlayLabel(for: item))
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
                Label("Details", systemImage: "info.circle").labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.platformGlass)
        .fixedSize(horizontal: titled, vertical: false)
        .focused($focusedButton, equals: .details)
    }

    /// A dot for each title, the one shown long.
    @ViewBuilder private var pages: some View {
        if items.count > 1 {
            let position = FeaturedRotation.position(of: shownId, in: items)
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    Capsule().fill(index == position ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: index == position ? 18 : 6, height: 6)
                }
            }
            // A touch target's height around dots 6 points high, taken back out of the
            // layout below so nothing around them moves.
            .frame(height: 44)
            .contentShape(.rect)
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

    /// "Resume · 1 hr, 10 min left", as the title's page has it, or "Play".
    private static func playLabel(for item: JellyfinItem) -> String {
        guard let resume = item.resumeSeconds else { return "Play" }
        guard let total = item.runtimeSeconds, total > resume else { return "Resume" }
        return "Resume · \(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
    }

    /// "Resume, 1 hour, 10 minutes left", rather than VoiceOver spelling out "hr" and "min".
    private static func spokenPlayLabel(for item: JellyfinItem) -> String {
        guard let resume = item.resumeSeconds else { return "Play" }
        guard let total = item.runtimeSeconds, total > resume else { return "Resume" }
        return "Resume, \(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .wide))) left"
    }

    /// Something might act on the title shown, so it doesn't turn on its own.
    private var holds: Bool {
        var holds = !mayTurn || isTouched || isHovered || focusedButton != nil || holdsStill
        #if os(macOS)
        holds = holds || isMenuOpen
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
        show(FeaturedRotation.id(after: shownId, by: step, in: items))
    }

    private func show(_ id: String?) {
        turnedAt = .now
        withAnimation(.easeInOut(duration: 0.6)) { shownId = id }
    }

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
