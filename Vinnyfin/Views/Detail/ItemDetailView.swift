import AppIntents
import SwiftUI

/// Where a title in a list leads: a show's page, a collection's titles, or a movie's or episode's page.
struct ItemDestination: View {
    let item: JellyfinItem

    var body: some View {
        if item.isSeries {
            SeriesView(series: item)
        } else if item.isSeason, let seriesId = item.seriesId {
            SeriesView(series: JellyfinItem(id: seriesId, name: item.seriesName ?? item.name, type: "Series"), initialSeasonId: item.id)
        } else if item.isCollection {
            LibraryGridView(list: .collection(item))
        } else {
            ItemDetailView(item: item)
        }
    }
}

extension View {
    /// Where the titles and lists in a navigation stack lead.
    func itemDestinations() -> some View {
        navigationDestination(for: JellyfinItem.self) { ItemDestination(item: $0) }
            .navigationDestination(for: BrowseList.self) { LibraryGridView(list: $0) }
    }

    /// Lets the stack's pages open a title as its next page where a link can't be, such as from
    /// a menu's command, by adding it to `path`. Every page is on the path, so a link on any of
    /// them leads on from it.
    func opensTitles(on path: Binding<NavigationPath>) -> some View {
        environment(\.openTitle, OpenTitleAction { path.wrappedValue.append($0) })
    }
}

/// Opens a title as the next page of the navigation stack it's called in (see `opensTitles(on:)`).
struct OpenTitleAction {
    let open: (JellyfinItem) -> Void

    func callAsFunction(_ item: JellyfinItem) {
        open(item)
    }
}

extension EnvironmentValues {
    @Entry var openTitle: OpenTitleAction?
}

/// A movie or an episode: play it, pick a version, download it, and more like it. An episode's
/// page leads to its show and has the show's seasons and episodes, and picking another episode
/// there shows that one in its place. Offline it shows the details and artwork saved with a download.
struct ItemDetailView: View {
    /// The title the page opened on.
    let item: JellyfinItem

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    /// Another episode of the show, picked on the page, that it shows in place of `item`.
    @State private var picked: JellyfinItem?
    @State private var detail: JellyfinItem?
    @State private var similar: [JellyfinItem] = []
    /// The title `similar` is like: an episode's show.
    @State private var similarTitleId: String?
    @State private var loadError: LoadFailure?
    /// A version the user picked, for plays and downloads from this page; nil lets them choose by
    /// quality. It isn't kept: every other playback starts with the version the quality allows.
    @State private var pickedSourceId: String?
    #if os(tvOS)
    @FocusState private var playFocused: Bool
    /// Focus has been put on Play, as the page first appeared.
    @State private var placedFocus = false
    #endif
    /// Back at the top for another episode picked, to show it.
    @State private var scrollPosition = ScrollPosition()

    /// The title the page shows.
    private var page: JellyfinItem { picked ?? item }

    /// The server's details, or until they come (offline, never) the ones saved with a download.
    private var loaded: JellyfinItem? {
        #if os(tvOS)
        detail
        #else
        detail ?? downloads.jobs(forItem: page.id).lazy.compactMap(\.item).first
        #endif
    }
    private var shown: JellyfinItem { loaded ?? page }
    private var sources: [MediaSource] { loaded?.mediaSources ?? [] }
    private var playbackSource: MediaSource? {
        sources.first { $0.id == pickedSourceId } ?? VersionChooser.choose(from: sources, limit: settings.streamingLimit)
    }

    var body: some View {
        EdgeToEdgeScrollView(underTopBars: true) {
            VStack(alignment: .leading, spacing: 28) {
                DetailHero(item: shown, eyebrow: shown.isEpisode ? shown.seriesName : nil, eyebrowLink: series,
                           badgesSource: playbackSource) {
                    actions
                }
                VStack(alignment: .leading, spacing: 28) {
                    if let loadError {
                        LoadFailureNotice(loadError) { Task { await load() } }
                            .padding(.horizontal, Metrics.edge)
                    }
                    if shown.isNotYetAvailable() { notYetAvailableNote }
                    OverviewText(item: shown).padding(.horizontal, Metrics.edge)
                    if sources.count > 1 { versions }
                    if page.isEpisode {
                        SeasonBrowser(episode: shown) { showEpisode($0) }
                    }
                    if let people = detail?.people { CastShelf(people: people) }
                    if !similar.isEmpty {
                        Shelf(title: "More Like This", seeAll: .moreLike(shown), items: similar, cardWidth: Metrics.posterWidth) { other in
                            NavigationLink(value: other) { PosterCard(item: other) }
                                .buttonStyle(.artwork)
                        }
                    }
                }
                .padding(.bottom, Metrics.edge)
            }
        }
        .scrollPosition($scrollPosition)
        // The page color the hero artwork fades into.
        .background(Color.pageBackground.ignoresSafeArea())
        .screenTitle(shown.name)
        .inlineNavigationTitle()
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .handoffPage(shown)
        // Siri knows which title the page is about: "play this", "download this".
        .appEntityIdentifier(EntityIdentifier.title(page))
        .task(id: page.id) { await load() }
        // A playback that ended moved where the title resumes, or finished it.
        .onChange(of: player.endedPlayback) {
            similar = player.endedPlayback.applied(to: similar)
            Task { await loadDetail() }
        }
        #if os(tvOS)
        // Focus starts on Play, also for a page opened from a link at launch, while focus is
        // still in the sidebar. Coming back to the page leaves focus where it was.
        .task {
            guard !placedFocus else { return }
            placedFocus = true
            playFocused = true
        }
        #endif
    }

    /// One row, or on a narrow screen Play above the rest, or with text too large for even
    /// that, one above the other.
    @ViewBuilder private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playButton
                secondaryButtons
            }
            VStack(alignment: .leading, spacing: 12) {
                playButton
                HStack(spacing: 12) { secondaryButtons }
            }
            VStack(alignment: .leading, spacing: 12) {
                playButton
                secondaryButtons
            }
        }
    }

    @ViewBuilder private var playButton: some View {
        if shown.isNotYetAvailable() {
            notYetAvailableButtons
        } else {
            #if os(tvOS)
            PlayButton(item: shown, mediaSourceId: pickedSourceId, focus: $playFocused)
            #else
            PlayButton(item: shown, mediaSourceId: pickedSourceId)
            #endif
        }
    }

    /// In Play's place for a title with nothing to play yet: that it isn't out, and Check Again,
    /// which has the server look for it once more, as it does each time the page loads.
    @ViewBuilder private var notYetAvailableButtons: some View {
        Label("Not Yet Available", systemImage: "clock")
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .platformGlass(in: .capsule)
            .fixedSize()
            .accessibilityIdentifier("detail.notYetAvailable")
        Button {
            Task { await loadDetail() }
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        #if os(tvOS)
        .focused($playFocused)
        #endif
        .accessibilityIdentifier("detail.checkAgain")
    }

    @ViewBuilder private var secondaryButtons: some View {
        let available = !shown.isNotYetAvailable()
        #if !os(tvOS)
        if available {
            DownloadButton(item: loaded, source: pickedSourceId.flatMap { id in sources.first { $0.id == id } })
        }
        #endif
        WatchedButton(item: shown) { detail = $0 }
        FavoriteButton(item: shown) { detail = $0 }
        if available {
            PlayElsewhereButton(subject: .title(shown, mediaSourceId: pickedSourceId))
        }
    }

    /// Why there's no Play, under the buttons: when it comes out, or that nothing's out yet.
    private var notYetAvailableNote: some View {
        let when = NotYetAvailableOverlay.day(of: shown).map { "\(shown.isEpisode ? "Airs" : "Comes out") \($0). " }
            ?? "Nothing of it is out yet. "
        return Text(when + "It plays here as soon as any copy of it is out, even one filmed in a theater.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, Metrics.edge)
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(sources.count) Versions").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                VersionPicker(sources: sources, selection: Binding(get: { playbackSource?.id }, set: { pickedSourceId = $0 }))
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 16))
            Text("Plays and downloads from this page use the version picked here. Everywhere else, and once you leave the page, they start with the one closest to your quality settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metrics.edge)
        .frame(maxWidth: 900, alignment: .leading)
    }

    /// The episode's show, which the name over its title leads to.
    private var series: JellyfinItem? {
        guard page.isEpisode, let seriesId = page.seriesId else { return nil }
        return JellyfinItem(id: seriesId, name: page.seriesName ?? "", type: "Series")
    }

    /// Shows another episode of the show in this one's place, from the top of the page, with
    /// Apple TV's focus on Play.
    private func showEpisode(_ episode: JellyfinItem) {
        guard episode.id != page.id else { return }
        let sameTitle = episode.titleId == page.titleId
        detail = nil
        pickedSourceId = nil
        loadError = nil
        if !sameTitle { similar = [] }
        picked = episode
        withAnimation { scrollPosition.scrollTo(edge: .top) }
        #if os(tvOS)
        playFocused = true
        #endif
    }

    private func load() async {
        let titleId = page.titleId
        await loadDetail()
        guard let session, similar.isEmpty || titleId != similarTitleId else { return }
        do {
            similar = try await session.client.similar(to: titleId, userId: session.userId)
            similarTitleId = titleId
        } catch {
            guard !error.isCancellation else { return }
            similar = []
            loadError = loadError ?? LoadFailure("Couldn't Load Titles Like This", error: error)
        }
    }

    private func loadDetail() async {
        guard let session else { return }
        let id = page.id
        do {
            let found = try await session.client.item(id: id, userId: session.userId)
            guard id == page.id else { return }
            detail = found
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = LoadFailure("Couldn't Load the Details", error: error)
        }
    }
}

/// Play, or Resume with the time left, plus Start Over when there's a position.
struct PlayButton: View {
    let item: JellyfinItem
    var mediaSourceId: String?
    #if os(tvOS)
    /// Play's focus, which the page starts on.
    let focus: FocusState<Bool>.Binding
    #endif
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            player.play(.item(item, mediaSourceId: mediaSourceId))
        } label: {
            Label(label, systemImage: "play.fill")
                .frame(minWidth: 120)
        }
        .buttonStyle(.platformGlassProminent)
        .controlSize(.large)
        // Its title on one line: the row's other buttons would otherwise take width it needs. At
        // the accessibility text sizes, where one line can be wider than the screen, it wraps.
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        .accessibilityLabel(spokenLabel)
        .accessibilityInputLabels([item.resumeSeconds != nil ? "Resume" : "Play", label])
        .accessibilityIdentifier("detail.play")
        #if os(tvOS)
        .focused(focus)
        #endif
        if item.resumeSeconds != nil {
            Button {
                player.play(.item(item, mediaSourceId: mediaSourceId, fromBeginning: true))
            } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.platformGlass)
            .controlSize(.large)
        }
    }

    private var label: String {
        guard let resume = item.resumeSeconds else { return "Play" }
        if let total = item.runtimeSeconds, total > resume {
            return "Resume · \(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
        }
        return "Resume"
    }

    /// "Resume, 1 hour, 20 minutes left", rather than VoiceOver spelling out "h" and "m".
    private var spokenLabel: String {
        guard let resume = item.resumeSeconds else { return "Play" }
        if let total = item.runtimeSeconds, total > resume {
            return "Resume, \(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .wide))) left"
        }
        return "Resume"
    }
}

struct WatchedButton: View {
    let item: JellyfinItem
    let onChange: (JellyfinItem) -> Void
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Label("Watched", systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        // A switch to VoiceOver, on when watched; its name stays, for Voice Control.
        .accessibilityAddTraits(item.isPlayed ? [.isToggle, .isSelected] : .isToggle)
        .help(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")
        .accessibilityIdentifier("detail.watched")
    }

    private func toggle() async {
        guard let session else { return }
        await WatchActions.setPlayed(!item.isPlayed, on: item, session: session, messages: messages, onChange: onChange)
    }
}

struct FavoriteButton: View {
    let item: JellyfinItem
    let onChange: (JellyfinItem) -> Void
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Label("Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .accessibilityAddTraits(item.isFavorite ? [.isToggle, .isSelected] : .isToggle)
        .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    private func toggle() async {
        guard let session else { return }
        await WatchActions.setFavorite(!item.isFavorite, on: item, session: session, messages: messages, onChange: onChange)
    }
}

#if !os(tvOS)
/// Download, then the download's progress, then a way to delete it.
struct DownloadButton: View {
    /// Nil until the item's versions have loaded.
    let item: JellyfinItem?
    /// A version the user picked; otherwise the download quality decides.
    let source: MediaSource?

    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages

    var body: some View {
        let jobs = item.map { downloads.jobs(forItem: $0.id) } ?? []
        Group {
            if jobs.contains(where: { $0.status == .completed }) {
                Menu {
                    Button("Delete Download", systemImage: "trash", role: .destructive) {
                        if let item { downloads.deleteDownloads(ofItem: item.id) }
                    }
                } label: {
                    Label("Downloaded", systemImage: "arrow.down.circle.fill")
                }
            } else if let job = jobs.first {
                Menu {
                    if job.status == .failed {
                        Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }
                    }
                    Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
                } label: {
                    if job.status == .failed {
                        Label("Download Failed", systemImage: "exclamationmark.circle")
                    } else {
                        Label {
                            Text("Downloading")
                        } icon: {
                            DownloadRing(job: job)
                        }
                    }
                }
                .accessibilityValue(job.status == .failed ? "" : DownloadRing.spokenProgress(of: job, downloads: downloads))
            } else {
                Button {
                    download()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(item == nil)
            }
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("detail.download")
    }

    private func download() {
        guard let item else { return }
        Task {
            if let problem = await downloads.download(item, picked: source, settings: settings) { messages.show(problem) }
        }
    }
}

/// A download's progress as a ring.
struct DownloadRing: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads
    /// As wide as a line of body text, growing with it.
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 18

    var body: some View {
        let fraction = Self.fraction(of: job, downloads: downloads)
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
            Circle().trim(from: 0, to: fraction).stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down").font(.system(size: diameter * 0.44, weight: .bold))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue(Self.spokenProgress(of: job, downloads: downloads))
    }

    static func fraction(of job: DownloadJob, downloads: DownloadManager) -> Double {
        let received = downloads.receivedBytes[job.id] ?? job.bytesOnDisk
        return job.displayTotalBytes.map { $0 > 0 ? Double(received) / Double($0) : 0 } ?? 0
    }

    /// "40 percent".
    static func spokenProgress(of job: DownloadJob, downloads: DownloadManager) -> String {
        "\(Int(fraction(of: job, downloads: downloads) * 100)) percent"
    }
}
#endif
