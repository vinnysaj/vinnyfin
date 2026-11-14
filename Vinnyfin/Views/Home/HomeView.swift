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
    @State private var feed = HomeFeed()
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
            EdgeToEdgeScrollView(underTopBars: !feed.featured.isEmpty) {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if !feed.featured.isEmpty {
                        HeroBanner(items: feed.featured) { path.append($0) }
                            #if os(tvOS)
                            .pageRow("hero", in: rowLayout)
                            #endif
                    }
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
                        HomeRowView(row: row, feed: feed) { path.append($0) }
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
            // On Apple TV, focus moves into Home at launch, and with nothing focusable there the
            // remote would do nothing at all; Check Again takes it.
            .overlay { if feed.hasNoTitles { noTitles } }
            // The page color the hero artwork fades into.
            .background(Color.pageBackground.ignoresSafeArea())
            .screenTitle("Home")
            #if os(tvOS)
            .toolbarVisibility(feed.featured.isEmpty ? .automatic : .hidden, for: .navigationBar)
            #elseif os(iOS) || os(visionOS)
            // Over the hero the bar keeps only its buttons (Remote on iPhone and iPad, Sounds and
            // Settings), floating on the artwork; on iPhone Duo they go in the vertical bar with
            // the rest of the bar's buttons.
            .navigationBarTitleDisplayMode(feed.featured.isEmpty ? .automatic : .inline)
            .toolbar(removing: feed.featured.isEmpty ? nil : .title)
            .toolbarBackgroundVisibility(feed.featured.isEmpty ? .automatic : .hidden, for: .navigationBar)
            #if os(iOS)
            .scrollEdgeEffectHidden(!feed.featured.isEmpty, for: .top)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .barTrailing) { remoteButton }
                #endif
                ToolbarItem(placement: .barTrailing) { soundsButton }
                ToolbarItem(placement: .barTrailing) { settingsButton }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
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
    let open: (JellyfinItem) -> Void

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
                .titleMenu(item) { feed.replace($0) } more: {
                    if item.isEpisode, let seriesId = item.seriesId {
                        Button("Go to Show", systemImage: "tv") {
                            open(JellyfinItem(id: seriesId, name: item.seriesName ?? "", type: "Series"))
                        }
                    }
                }
        }
    }

    private func problemRow(_ problem: String) -> some View {
        LoadFailureNotice(LoadFailure("Couldn't Load \(row.list.title)", message: problem)) { feed.retry(row.id) }
            .padding(.horizontal, Metrics.edge)
    }
}

/// The featured titles, one at a time across the top, turning every few seconds. It holds still
/// while one of its buttons has focus, so the title they act on doesn't change under them, and
/// with Reduce Motion, VoiceOver or Switch Control on, which would have it change under them too;
/// there the titles turn by hand, with the adjustable dots.
private struct HeroBanner: View {
    let items: [JellyfinItem]
    let openDetails: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.topBarsHeight) private var topBarsHeight
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var index = 0
    @State private var isInteracting = false
    @FocusState private var focusedButton: HeroButton?
    #if os(tvOS)
    /// Bounds the banner's default focus, so it's the banner's to take when focus comes in.
    @Namespace private var focusScope
    #endif

    private enum HeroButton {
        case play, details
    }

    var body: some View {
        let item = items[min(index, items.count - 1)]
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                Artwork(url: session?.backdrop(item), aspectRatio: nil, cornerRadius: 0)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .id(item.id)
                    .transition(.opacity)
                    .overlay { DetailHero<EmptyView>.scrim(increased: contrast == .increased, from: 0.3, middle: 0.7, at: 0.72) }
                    // Past the safe area at the sides, under any bars there: clipped and faded first,
                    // so that part is too.
                    .ignoresSafeArea(edges: .horizontal)
                VStack(alignment: .leading, spacing: 10) {
                    heading(item)
                    if !isStacked { details(item) }
                }
                .padding(.horizontal, Metrics.edge)
                .padding(.bottom, 6)
                // Grown taller than the artwork by larger text, the words stay clear of the bars over it.
                .padding(.top, topBarsHeight)
            }
            if isStacked {
                VStack(alignment: .leading, spacing: 10) { details(item) }
                    .padding(.horizontal, Metrics.edge)
                    .padding(.bottom, 6)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: index)
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { _ in isInteracting = true }
                .onEnded { value in
                    isInteracting = false
                    if value.translation.width < -40 { turn(by: 1) }
                    if value.translation.width > 40 { turn(by: -1) }
                }
        )
        #endif
        #if os(tvOS)
        .focusSection()
        .focusScope(focusScope)
        // Up from the rows, focus goes to the title's main button, not whichever is above the
        // card it leaves.
        .defaultFocus($focusedButton, Self.showsPlay(for: item) ? .play : .details, priority: .userInitiated)
        #endif
        .task(id: items.map(\.id)) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if !isInteracting, focusedButton == nil, !holdsStill, !Task.isCancelled { turn(by: 1) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.hero")
    }

    /// At the accessibility sizes, all but the title go under the picture rather than over it,
    /// where they would run up past the fade into the page, onto the picture itself.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The title, as its logo when there is one.
    @ViewBuilder private func heading(_ item: JellyfinItem) -> some View {
        Group {
            if let logo = session?.logo(item) {
                Artwork(url: logo, aspectRatio: nil, cornerRadius: 0, placeholder: "", contentMode: .fit, label: item.name)
                    .frame(maxWidth: logoWidth, maxHeight: logoHeight, alignment: .leading)
            } else {
                Text(item.name).font(.largeTitle.weight(.bold)).lineLimit(dynamicTypeSize.lineLimit(2))
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// Whether the banner offers to play the title: one that plays, and is out.
    private static func showsPlay(for item: JellyfinItem) -> Bool {
        item.isPlayable && !item.isNotYetAvailable()
    }

    /// The facts, the overview, the buttons and the dots.
    @ViewBuilder private func details(_ item: JellyfinItem) -> some View {
        Text(DetailHero<EmptyView>.facts(for: item))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityLabel(DetailHero<EmptyView>.spokenFacts(for: item))
        if let overview = item.overview {
            Text(overview).font(.subheadline).lineLimit(dynamicTypeSize.lineLimit(2)).frame(maxWidth: 640, alignment: .leading)
        }
        AdaptiveStack(spacing: 12) {
            if Self.showsPlay(for: item) {
                Button {
                    player.play(.item(item))
                } label: {
                    Label(item.resumeSeconds != nil ? "Resume" : "Play", systemImage: "play.fill")
                }
                .buttonStyle(.platformGlassProminent)
                .focused($focusedButton, equals: .play)
            }
            Button {
                openDetails(item)
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            .buttonStyle(.platformGlass)
            .focused($focusedButton, equals: .details)
        }
        .controlSize(.large)
        if items.count > 1 {
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { position in
                    Capsule().fill(position == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: position == index ? 18 : 6, height: 6)
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
            .accessibilityValue("\(index + 1) of \(items.count)")
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

    /// Reduce Motion asks for no motion that goes on by itself; VoiceOver and Switch Control move
    /// through the banner one piece at a time, and a title turning would change it under them.
    private var holdsStill: Bool {
        reduceMotion || voiceOverEnabled || switchControlEnabled
    }

    private func turn(by step: Int) {
        guard !items.isEmpty else { return }
        index = (index + step + items.count) % items.count
    }

    private var height: CGFloat {
        #if os(tvOS)
        820
        #elseif os(iOS)
        sizeClass == .regular ? 580 : 500
        #else
        520
        #endif
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var logoHeight: CGFloat {
        #if os(tvOS)
        200
        #else
        100
        #endif
    }
}
