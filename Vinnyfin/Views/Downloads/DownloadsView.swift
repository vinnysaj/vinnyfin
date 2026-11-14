#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// Everything on this device: downloads in progress and done, movies and then each show with
/// what's downloaded of it and how it's kept downloaded, and video files from elsewhere. Works
/// with or without a connection.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadNotifications.self) private var downloadNotifications
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(LocalLibrary.self) private var localLibrary
    @Environment(WatchHistory.self) private var history
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    #if os(iOS) || os(visionOS)
    @Environment(BackgroundDownloads.self) private var backgroundDownloads
    #endif
    #if os(iOS) || os(macOS)
    @Environment(WidgetDownloads.self) private var widgetDownloads
    #endif
    @Environment(\.openURL) private var openURL
    @State private var importing = false
    /// The tab's pages, which a link opens a title on; nil when Downloads keeps its own, as a sheet.
    private let tabPath: Binding<NavigationPath>?
    @State private var ownPath = NavigationPath()

    init(path: Binding<NavigationPath>? = nil) {
        tabPath = path
    }

    /// The pages open on top of Downloads: the titles it leads to.
    private var path: Binding<NavigationPath> { tabPath ?? $ownPath }

    private var unfinished: [DownloadJob] { downloads.jobs.filter { $0.status != .completed } }

    var body: some View {
        let groups = DownloadGroups(finished: downloads.jobs.filter { $0.status == .completed }, rules: smartDownloads.rulesByShow)
        NavigationStack(path: path) {
            List {
                problems
                #if os(iOS) || os(visionOS)
                BackgroundNotices(hasActiveDownloads: unfinished.contains { $0.status == .active })
                #endif
                spaceNotice
                if isEmpty {
                    Section { emptyState }
                        .listRowBackground(Color.clear)
                }
                if !unfinished.isEmpty {
                    Section {
                        ForEach(unfinished) { job in JobRow(job: job, isFirst: job.id == unfinished.first?.id) }
                            .onMove { from, to in
                                var order = unfinished.map(\.id)
                                order.move(fromOffsets: from, toOffset: to)
                                downloads.reorderUnfinished(order)
                            }
                    } header: {
                        Text("Downloading")
                    } footer: {
                        if unfinished.count > 1 {
                            Text("Downloads go one at a time, in this order. Drag one to move it, or choose Download Next.")
                        }
                    }
                }
                if !groups.movies.isEmpty {
                    Section("Movies") {
                        ForEach(groups.movies) { job in DownloadedRow(job: job) }
                    }
                }
                ForEach(groups.shows) { show in ShowSection(show: show) }
                LocalFilesSection()
                Section {
                    storageSummary
                } footer: {
                    Text(FinishedFiles.hint)
                }
            }
            .navigationTitle("Downloads")
            .toolbar { toolbar }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.videoTypes, allowsMultipleSelection: false) { result in
                openPicked(result)
            }
            .onAppear { localLibrary.scanFolder(excluding: Set(downloads.jobs.compactMap(\.savedPath))) }
            .itemDestinations()
        }
        .opensTitles(on: path)
    }

    private var isEmpty: Bool {
        downloads.jobs.isEmpty && smartDownloads.rules.isEmpty && localLibrary.recents.isEmpty && localLibrary.folderFiles.isEmpty
    }

    /// In the list above the storage summary: over the list, in the middle of the screen, it would
    /// run into the summary at the larger text sizes, and into notices at any.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing Downloaded", systemImage: "arrow.down.circle")
        } description: {
            Text("Download movies and episodes to watch them offline, or open a video file from this device.")
        } actions: {
            Button("Open a File…") { importing = true }
                .buttonStyle(.platformGlass)
                .controlSize(.large)
        }
    }

    /// Each problem to show, with how to dismiss it.
    private var problemMessages: [(String, () -> Void)] {
        var messages: [(String, () -> Void)?] = [
            downloads.problem.map { ($0, { downloads.problem = nil }) },
            smartDownloads.problem.map { ($0, { smartDownloads.problem = nil }) },
            downloadNotifications.problem.map { ($0, { downloadNotifications.problem = nil }) },
            history.problem.map { ($0, { history.problem = nil }) },
            localLibrary.problem.map { ($0, { localLibrary.problem = nil }) },
        ]
        #if os(iOS) || os(visionOS)
        messages.append(backgroundDownloads.problem.map { ($0, { backgroundDownloads.problem = nil }) })
        #endif
        #if os(iOS) || os(macOS)
        messages.append(widgetDownloads.problem.map { ($0, { widgetDownloads.problem = nil }) })
        #endif
        return messages.compactMap(\.self)
    }

    @ViewBuilder private var problems: some View {
        let messages = problemMessages
        if !messages.isEmpty {
            Section {
                ForEach(messages.indices, id: \.self) { index in
                    Label(messages[index].0, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Button("Dismiss") { messages.forEach { $0.1() } }
            }
        }
    }

    /// What to do when downloads wait for room.
    @ViewBuilder private var spaceNotice: some View {
        if downloads.waits.values.contains(where: { if case .space = $0 { true } else { false } }) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not enough space for downloads", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Downloads wait until there's room. \(StorageBudget.advice(hasLimit: settings.downloadStorageLimit > 0)) \(StorageUsage.deletionPolicy)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("notice.space")
            }
        }
    }

    @ViewBuilder private var storageSummary: some View {
        StorageUsage()
        if let free = downloads.availableCapacity() {
            LabeledContent("Free on This \(Device.name)", value: DownloadManager.bytes(free))
        }
        if let freed = downloads.lastFreed {
            Text("To make room, \(freed.date.formatted(.relative(presentation: .named))) vinnyfin deleted \(ListFormatter.localizedString(byJoining: freed.titles)), watched since \(freed.titles.count == 1 ? "it was" : "they were") downloaded (\(DownloadManager.bytes(freed.bytes))).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .barTrailing) {
            Button("Open File", systemImage: "folder.badge.plus") { importing = true }
                .help("Open a video file")
                .accessibilityIdentifier("downloads.openFile")
        }
        ToolbarItem(placement: .barTrailing) {
            Menu {
                Button("Show in \(FinishedFiles.browser)", systemImage: "folder") {
                    openURL(FinishedFiles.browserURL(for: downloads.finishedFolder))
                }
                Button("Pause All", systemImage: "pause") { downloads.pauseAll() }
                    .disabled(!unfinished.contains { $0.status == .active })
                    .accessibilityIdentifier("downloads.pauseAll")
                Button("Resume All", systemImage: "play") { downloads.resumeAll() }
                    .disabled(!unfinished.contains { $0.status == .paused })
                    .accessibilityIdentifier("downloads.resumeAll")
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More")
            .accessibilityIdentifier("downloads.more")
        }
    }

    static let videoTypes: [UTType] = [.movie, .video, .audiovisualContent] + ["mkv", "webm", "avi", "ts", "m2ts", "wmv", "flv", "ogv", "vob"]
        .compactMap { UTType(filenameExtension: $0) }

    private func openPicked(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            player.playFile(url)
        case .failure(let error):
            localLibrary.problem = "Couldn't open the file: \(error.localizedDescription)"
        }
    }
}

/// A download that hasn't finished, with its progress and a ring to pause or resume it by.
private struct JobRow: View {
    let job: DownloadJob
    /// First in the list, so first to download.
    let isFirst: Bool
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The network or Only While Charging holds it back, which Download Now lifts.
    private var mayDownloadNow: Bool {
        job.status == .active && downloads.waits[job.id]?.isRule == true
    }

    var body: some View {
        HStack(spacing: 12) {
            AdaptiveStack(spacing: 12) {
                OfflineArtwork(itemId: job.itemId, aspectRatio: job.isEpisode ? 16.0 / 9.0 : 2.0 / 3.0)
                    .frame(width: job.isEpisode ? 96 : 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    if let subtitle = job.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let line = job.versionLine {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                    Group {
                        JobProgress(job: job)
                        JobStatusLine(job: job)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            JobRing(job: job)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("job.\(job.title)")
        .swipeActions(edge: .trailing) {
            Button("Cancel", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
        }
        .swipeActions(edge: .leading) {
            switch job.status {
            case .active:
                Button("Pause", systemImage: "pause") { downloads.pause(job.id) }.tint(.orange)
                if mayDownloadNow {
                    Button("Download Now", systemImage: "arrow.down.to.line") { downloads.downloadNow(job.id) }.tint(.blue)
                }
            case .paused:
                Button("Resume", systemImage: "play") { downloads.resume(job.id) }.tint(.green)
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }.tint(.blue)
            case .completed:
                EmptyView()
            }
        }
        .contextMenu {
            if mayDownloadNow {
                Button("Download Now", systemImage: "arrow.down.to.line") { downloads.downloadNow(job.id) }
            }
            downloadNext
            switch job.status {
            case .active:
                Button("Pause", systemImage: "pause") { downloads.pause(job.id) }
            case .paused:
                Button("Resume", systemImage: "play") { downloads.resume(job.id) }
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }
                startOver
            case .completed:
                EmptyView()
            }
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
        }
        // What only the long press offers, among the swipe actions VoiceOver, Voice Control and
        // Switch Control already have; Download Next stands in for dragging it to the top.
        .accessibilityActions {
            downloadNext
            if job.status == .failed { startOver }
        }
    }

    @ViewBuilder private var downloadNext: some View {
        if !isFirst {
            Button("Download Next", systemImage: "text.line.first.and.arrowtriangle.forward") { downloads.downloadNext(job.id) }
        }
    }

    private var startOver: some View {
        Button("Start Over", systemImage: "arrow.counterclockwise") { downloads.restart(job.id) }
    }
}

/// How far a download has got, round the one thing to do with it from here: pause it while it
/// downloads or waits, resume it once paused, retry it once it failed.
private struct JobRing: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads
    /// The height of a line of title text, growing with it.
    @ScaledMetric(relativeTo: .title2) private var diameter: CGFloat = 30

    var body: some View {
        Button(action: act) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
                Circle().trim(from: 0, to: DownloadRing.fraction(of: job, downloads: downloads))
                    .stroke(job.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.36, weight: .bold))
                    .foregroundStyle(job.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            }
            .frame(width: diameter, height: diameter)
            .padding(6)
            .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(DownloadRing.spokenProgress(of: job, downloads: downloads))
        .accessibilityIdentifier("job.\(job.title).ring")
    }

    private var title: String {
        switch job.status {
        case .active, .completed: "Pause"
        case .paused: "Resume"
        case .failed: "Retry"
        }
    }

    private var symbol: String {
        switch job.status {
        case .active, .completed: "pause.fill"
        case .paused: "arrow.down"
        case .failed: "arrow.clockwise"
        }
    }

    private func act() {
        switch job.status {
        case .active: downloads.pause(job.id)
        case .paused, .failed: downloads.resume(job.id)
        case .completed: break
        }
    }
}

/// A show's downloads: a row with its poster, what's downloaded and how it's kept downloaded,
/// with the way to its page, to the ways to keep it and to delete what's downloaded; then the
/// episodes; then, below, the watched ones lately deleted.
private struct ShowSection: View {
    let show: DownloadGroups.Show
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        Section {
            ShowRow(show: show)
            ForEach(show.episodes) { job in DownloadedRow(job: job) }
        } footer: {
            if let removal = downloads.watchedRemovals[show.id], removal.isRecent(at: .now) {
                Text(Self.note(removal))
            }
        }
    }

    /// "S01E01 was deleted yesterday, once you'd watched it (812 MB)."
    static func note(_ removal: WatchedRemoval) -> String {
        let episodes = ListFormatter.localizedString(byJoining: removal.episodes)
        let verb = removal.episodes.count == 1 ? "was" : "were"
        let when = removal.date.formatted(.relative(presentation: .named))
        let pronoun = removal.episodes.count == 1 ? "it" : "them"
        return "\(episodes) \(verb) deleted \(when), once you'd watched \(pronoun) (\(DownloadManager.bytes(removal.bytes)))."
    }
}

/// The first row of a show's section in Downloads.
private struct ShowRow: View {
    let show: DownloadGroups.Show
    @Environment(\.session) private var session
    @Environment(\.openTitle) private var openTitle
    @Environment(DownloadManager.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(WatchHistory.self) private var history
    @State private var deleting: Deletion?

    private enum Deletion: Identifiable {
        case watched([DownloadJob])
        case all

        var id: String {
            switch self {
            case .watched: "watched"
            case .all: "all"
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                OfflineArtwork(itemId: show.seriesId ?? show.id, aspectRatio: 2.0 / 3.0).frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.name).font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    if let rule = show.rule {
                        Label {
                            Text(rule.episodesAhead.map { "Keeping the next \($0) downloaded" } ?? "Keeping every unwatched episode")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(.tint)
                        }
                        .labelStyle(InlineLabelStyle())
                        .font(.caption)
                        if let owner = smartDownloads.pausedOwner(of: rule) {
                            Label(DownloadWait.account(owner).status, systemImage: DownloadWait.account(owner).systemImage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            menu
        }
        .accessibilityIdentifier("show.\(show.name)")
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { deletion in
            switch deletion {
            case .watched(let watched):
                Button("Delete Watched Episodes", role: .destructive) {
                    for job in watched { downloads.deleteDownloads(ofItem: job.itemId) }
                }
            case .all:
                Button(show.rule == nil ? "Delete All Episodes" : "Delete All and Stop Smart Downloads", role: .destructive) {
                    if let rule = show.rule { smartDownloads.remove(rule) }
                    for job in downloads.jobs where job.isEpisode && job.showKey == show.id {
                        downloads.deleteDownloads(ofItem: job.itemId)
                    }
                }
            }
        } message: { deletion in
            Text(dialogMessage(deletion))
        }
    }

    /// "3 episodes · 25.5 MB", or with none downloaded, that the next are on their way.
    private var summary: String {
        guard !show.episodes.isEmpty else { return "No episodes downloaded right now" }
        let count = show.episodes.count == 1 ? "1 episode" : "\(show.episodes.count) episodes"
        return "\(count) · \(DownloadManager.bytes(show.bytes))"
    }

    @ViewBuilder private var menu: some View {
        if let seriesId = show.seriesId {
            SmartDownloadMenu(seriesId: seriesId, seriesName: show.name) {
                actions
            } label: {
                menuLabel
            }
            .accessibilityLabel("Options for \(show.name)")
        } else {
            Menu { actions } label: { menuLabel }
                .accessibilityLabel("Options for \(show.name)")
        }
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis.circle").font(.title2).padding(6).contentShape(.rect)
            .help("Options for \(show.name)")
    }

    @ViewBuilder private var actions: some View {
        // Another sign-in's, which the menu's own Stop, for the sign-in in use's, doesn't stop.
        if let rule = show.rule, smartDownloads.pausedOwner(of: rule) != nil {
            Button("Stop Smart Downloads", systemImage: "xmark", role: .destructive) { smartDownloads.remove(rule) }
        }
        if session != nil, let seriesId = show.seriesId, let openTitle {
            Button("Go to Show", systemImage: "tv") {
                openTitle(JellyfinItem(id: seriesId, name: show.name, type: "Series"))
            }
        }
        if !show.episodes.isEmpty {
            let watched = watchedEpisodes
            Button("Delete Watched", systemImage: "checkmark.circle") { deleting = .watched(watched) }
                .disabled(watched.isEmpty)
            Button("Delete All", systemImage: "trash", role: .destructive) { deleting = .all }
        }
    }

    private var watchedEpisodes: [DownloadJob] {
        show.episodes.filter { $0.watchState(local: history.entry(for: $0.itemId)).isWatched }
    }

    private var dialogTitle: String {
        switch deleting {
        case .watched(let watched): "Delete \(watched.count == 1 ? "1 watched episode" : "\(watched.count) watched episodes") of \(show.name)?"
        case .all, nil: "Delete every downloaded episode of \(show.name)?"
        }
    }

    private func dialogMessage(_ deletion: Deletion) -> String {
        switch deletion {
        case .watched(let watched):
            return "Frees \(DownloadManager.bytes(watched.reduce(0) { $0 + $1.storedBytes }))."
        case .all:
            let frees = "Frees \(DownloadManager.bytes(show.bytes))"
            return show.rule == nil ? "\(frees)." : "\(frees), and stops keeping \(show.name) downloaded."
        }
    }
}

/// A finished download: plays when chosen, shows how far it was watched, and leads to its title.
private struct DownloadedRow: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads
    @Environment(WatchHistory.self) private var history
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.session) private var session
    @Environment(\.openTitle) private var openTitle
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmingDelete = false

    var body: some View {
        Button {
            player.play(PlaybackRequest(source: .item(id: job.itemId, mediaSourceId: job.mediaSourceId), title: job.title))
        } label: {
            AdaptiveStack(spacing: 12) {
                OfflineArtwork(itemId: job.itemId, aspectRatio: job.isEpisode ? 16.0 / 9.0 : 2.0 / 3.0)
                    .frame(width: job.isEpisode ? 110 : 50)
                    .overlay(alignment: .bottom) {
                        if let progress { ProgressBar(fraction: progress).padding(4) }
                    }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.isEpisode ? [job.item?.episodeCode, job.title].compactMap(\.self).joined(separator: " · ") : job.title)
                            .font(.body.weight(.medium))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .accessibilityLabel(job.isEpisode ? [job.item?.spokenEpisodeCode, job.title].compactMap(\.self).joined(separator: ", ")
                                                              : job.title)
                        detailLine
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isWatched {
                            // The tint on the mark alone: the green reads at under 3 to 1 as text.
                            Label {
                                Text("Watched").foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                            .labelStyle(InlineLabelStyle())
                            .font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays it")
        .accessibilityIdentifier("downloaded.\(job.title)")
        .swipeActions(edge: .trailing) {
            // Not the destructive role: that takes the row out of the list at once, and the
            // dialog with it, and nothing is deleted.
            Button("Delete", systemImage: "trash") { confirmingDelete = true }.tint(.red)
        }
        .contextMenu {
            goToTitle
            if let file = downloads.savedFileURL(of: job) {
                showInFiles(file)
                ShareLink(item: file)
            }
            Button("Delete Download", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        // What only the long press offers, beside the swipe's Delete that VoiceOver, Voice Control
        // and Switch Control already have. Sharing needs the menu's own sheet, which a long press
        // still opens for them: VoiceOver's double-tap held, Voice Control's "Long press".
        .accessibilityActions {
            goToTitle
            if let file = downloads.savedFileURL(of: job) { showInFiles(file) }
        }
        .confirmationDialog("Delete \(job.title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Download", role: .destructive) { downloads.deleteDownloads(ofItem: job.itemId) }
        } message: {
            Text("Frees \(DownloadManager.bytes(freedBytes)). You can download it again any time.")
        }
    }

    /// The show's page for an episode, the movie's for a movie, while signed in where they're from.
    @ViewBuilder private var goToTitle: some View {
        if session != nil, let openTitle {
            if job.isEpisode {
                if let seriesId = job.seriesId {
                    Button("Go to Show", systemImage: "tv") {
                        openTitle(JellyfinItem(id: seriesId, name: job.showName, type: "Series"))
                    }
                }
            } else {
                Button("Go to Movie", systemImage: "film") {
                    openTitle(job.item ?? JellyfinItem(id: job.itemId, name: job.title, type: "Movie"))
                }
            }
        }
    }

    private func showInFiles(_ file: URL) -> some View {
        Button("Show in \(FinishedFiles.browser)", systemImage: "folder") {
            openURL(FinishedFiles.browserURL(for: file.deletingLastPathComponent()))
        }
    }

    /// What the version is, then its size, which is never what's cut short.
    @ViewBuilder private var detailLine: some View {
        let size = DownloadManager.bytes(job.storedBytes)
        if let version = job.versionLine {
            if dynamicTypeSize.isAccessibilitySize {
                Text("\(version) · \(size)")
            } else {
                HStack(spacing: 0) {
                    Text(version).lineLimit(1)
                    Text(" · \(size)").lineLimit(1).layoutPriority(1)
                }
            }
        } else {
            Text(size)
        }
    }

    /// What deleting it frees: its downloads, finished and not, as far as they've got.
    private var freedBytes: Int64 {
        downloads.jobs.filter { $0.itemId == job.itemId }
            .reduce(0) { $0 + ($1.status == .completed ? $1.storedBytes : $1.bytesOnDisk) }
    }

    private var entry: WatchHistory.Entry? { history.entry(for: job.itemId) }

    private var isWatched: Bool {
        job.watchState(local: entry).isWatched
    }

    private var progress: Double? {
        if let entry, let duration = entry.duration, duration > 0, entry.position > 0, !entry.played {
            return entry.position / duration
        }
        return entry == nil ? job.item?.progress : nil
    }
}

#if os(iOS) || os(visionOS)
/// What holds downloads back outside the app, with what to do about it.
private struct BackgroundNotices: View {
    let hasActiveDownloads: Bool
    @Environment(BackgroundDownloads.self) private var backgroundDownloads
    @Environment(\.openURL) private var openURL

    var body: some View {
        let notices = backgroundDownloads.notices(hasActiveDownloads: hasActiveDownloads)
        if !notices.isEmpty {
            Section {
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(notice.title, systemImage: notice.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("notice.\(notice.rawValue)")
                        Text(notice.message).font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            if notice.opensSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                                Button("Open Settings") { openURL(settings) }
                                    .accessibilityIdentifier("notice.\(notice.rawValue).settings")
                            }
                            Button("Dismiss") { backgroundDownloads.dismiss(notice) }
                                .accessibilityIdentifier("notice.\(notice.rawValue).dismiss")
                        }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
#endif

/// How much room downloads take, against the storage limit when there is one.
struct StorageUsage: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings

    static let deletionPolicy = "Downloads you've watched since you downloaded them are deleted to make room by themselves; unwatched and partly watched ones never are, nor ones you'd already watched when you downloaded them."

    var body: some View {
        let used = downloads.storageUsed
        let limit = DownloadRules(settings).storageLimit
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Downloads Use") {
                Text(limit.map { "\(DownloadManager.bytes(used)) of \(DownloadManager.bytes($0))" } ?? DownloadManager.bytes(used))
                    .monospacedDigit()
            }
            if let limit {
                ProgressView(value: Double(min(used, limit)), total: Double(limit))
                    .tint(used >= limit ? .orange : .accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage.usage")
    }
}

/// Artwork saved with a download, shown from disk so it works offline.
struct OfflineArtwork: View {
    let itemId: String
    let aspectRatio: CGFloat
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        Artwork(url: downloads.artworkURL(itemId: itemId, kind: .primary), aspectRatio: aspectRatio, cornerRadius: 6)
    }
}
#endif
