#if !os(tvOS)
import Foundation
import Observation
import OSLog
import UserNotifications
#if os(iOS) || os(visionOS)
import UIKit
#endif

/// Tells the user, through the system's notifications, when downloads are ready to watch
/// offline and when one needs them: it failed, there's no room for it, or the server has been
/// out of reach for over `DownloadAttention.unreachableLimit`.
///
/// Permission is asked the first time someone starts a download, not at launch. A show's
/// episodes share one notification, which counts them as they come ("3 episodes of Port Ellery
/// are ready"): the count carries on from the one still showing, so it holds across launches,
/// and later episodes update it quietly. Downloads finishing together go out together, after
/// `gathering`. What needs attention is one notification too, posted only when something new
/// needs it, and taken away once nothing does. Nothing shows while vinnyfin is in front, where
/// the Downloads screen says it all. Posting keeps the app running long enough to finish
/// (`beginBackgroundTask`), so it works from a background launch: the session's wake, the
/// catch-up and continued-processing tasks.
///
/// A title that's ready shows with its poster, and offers Play and Open. Tapping one, or Open,
/// opens its title through `IncomingLinks`, which the root view follows like any vinnyfin://
/// link, under the sign-in that downloaded it; Play plays it.
@Observable
final class DownloadNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// How long to wait for more downloads finishing together before posting.
    static let gathering: Duration = .seconds(1)
    private static let attentionIdentifier = "attention"
    private static let toldKey = "downloads.notifiedAttention"
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "notifications")

    private(set) var authorizationStatus = UNAuthorizationStatus.notDetermined
    /// Someone said no, in the prompt or in system settings, which is the only place to say yes again.
    var isDenied: Bool { authorizationStatus == .denied }
    /// Why notifications couldn't be asked for or posted, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let links: IncomingLinks
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingReady: [DownloadJob] = []
    /// The posters of `pendingReady`'s titles, by item.
    @ObservationIgnored private var pendingPosters: [String: URL] = [:]
    /// What needs attention, to post once gathering is over.
    @ObservationIgnored private var pendingAttention: AttentionNotice?
    @ObservationIgnored private var isAttentionResolved = false
    @ObservationIgnored private var posting: Task<Void, Never>?
    #if os(iOS) || os(visionOS)
    /// The background time held while posting.
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif
    /// What the user has been told needs attention, kept so a relaunch doesn't tell them again.
    @ObservationIgnored private var told: Set<DownloadAttention>
    @ObservationIgnored private var isRequestingAuthorization = false

    init(settings: AppSettings, links: IncomingLinks, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.links = links
        self.defaults = defaults
        told = Set((defaults.stringArray(forKey: Self.toldKey) ?? []).compactMap(DownloadAttention.init(key:)))
    }

    /// Takes the notifications' responses from here on. Has to run before the app finishes
    /// launching, to hear about the tap that launched it.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([ReadyNotice.category])
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status != authorizationStatus { authorizationStatus = status }
    }

    /// Asks once whether vinnyfin may notify, as someone starts a download or turns the setting on.
    func requestAuthorizationIfNeeded() {
        guard settings.downloadNotifications, !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        Task {
            defer { isRequestingAuthorization = false }
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Self.log.info("Notifications \(granted ? "allowed" : "declined", privacy: .public)")
            } catch {
                problem = "Couldn't ask to send notifications: \(error.localizedDescription)"
            }
            await refreshAuthorization()
        }
    }

    /// A download has been published, with the poster saved for it, which its notification shows.
    func ready(_ job: DownloadJob, poster: URL? = nil) {
        pendingReady.append(job)
        if let poster { pendingPosters[job.itemId] = poster }
        postSoon()
    }

    /// The state of the downloads, after each change: anything newly in need of attention is
    /// told, and once nothing is, the notification goes.
    func attentionChanged(jobs: [DownloadJob], waits: [UUID: DownloadWait], isNetworkReachable: Bool, serverName: String?, now: Date) {
        let current = DownloadAttention.current(jobs: jobs, waits: waits, isNetworkReachable: isNetworkReachable, now: now)
        let isNew = !current.isSubset(of: told)
        guard current != told else { return }
        told = current
        defaults.set(current.map(\.key).sorted(), forKey: Self.toldKey)
        if current.isEmpty {
            pendingAttention = nil
            isAttentionResolved = true
        } else if isNew {
            pendingAttention = AttentionNotice(current, jobs: jobs, waits: waits, serverName: serverName,
                                               hasStorageLimit: settings.downloadStorageLimit > 0)
            isAttentionResolved = false
        } else {
            return
        }
        postSoon()
    }

    // MARK: Posting

    private func postSoon() {
        guard posting == nil else { return }
        #if os(iOS) || os(visionOS)
        // Given back when the system wants it, or it ends the app.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Download notifications") { [weak self] in
            self?.endBackgroundTask()
        }
        #endif
        posting = Task {
            try? await Task.sleep(for: Self.gathering)
            await post()
            posting = nil
            #if os(iOS) || os(visionOS)
            endBackgroundTask()
            #endif
            if !pendingReady.isEmpty || pendingAttention != nil || isAttentionResolved { postSoon() }
        }
    }

    #if os(iOS) || os(visionOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    private func post() async {
        let ready = pendingReady
        let posters = pendingPosters
        let attention = pendingAttention
        let isResolved = isAttentionResolved
        pendingReady = []
        pendingPosters = [:]
        pendingAttention = nil
        isAttentionResolved = false
        let center = UNUserNotificationCenter.current()
        if isResolved { center.removeDeliveredNotifications(withIdentifiers: [Self.attentionIdentifier]) }
        guard settings.downloadNotifications, !ready.isEmpty || attention != nil else { return }
        await refreshAuthorization()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        var requests: [UNNotificationRequest] = []
        if !ready.isEmpty {
            var delivered: [String: [String]] = [:]
            for notification in await center.deliveredNotifications() {
                let request = notification.request
                if let items = request.content.userInfo[ReadyNotice.itemsKey] as? [String] { delivered[request.identifier] = items }
            }
            for notice in ReadyNotice.notices(for: ready, delivered: delivered, posters: posters) {
                let content = notice.content(attachments: notice.poster.flatMap(Self.attachment).map { [$0] } ?? [])
                requests.append(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
            }
        }
        if let attention {
            requests.append(UNNotificationRequest(identifier: Self.attentionIdentifier,
                                                  content: attention.content(thread: Self.attentionIdentifier), trigger: nil))
        }
        for request in requests {
            do {
                try await center.add(request)
                Self.log.info("Posted \(request.identifier, privacy: .public): \(request.content.body, privacy: .public)")
            } catch {
                problem = "Couldn't post a notification: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Responses

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        []
    }

    /// A tap, or Open, opens the title's page; Play plays it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, ReadyNotice.openAction: ReadyNotice.linkKey
        case ReadyNotice.playAction: ReadyNotice.playLinkKey
        default: String?.none
        }
        guard let key, let link = (response.notification.request.content.userInfo[key] as? String).flatMap(URL.init(string:))
        else { return }
        await open(link)
    }

    private func open(_ link: URL) {
        links.open(link)
    }

    /// A copy of the poster for a notification to show, which the system takes the file of;
    /// nil when it can't be had.
    private static func attachment(of poster: URL) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(poster.pathExtension.isEmpty ? "jpg" : poster.pathExtension)")
        do {
            try FileManager.default.copyItem(at: poster, to: copy)
            return try UNNotificationAttachment(identifier: "poster", url: copy)
        } catch {
            log.error("Couldn't attach the poster to a notification: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }
}

// MARK: Content

/// A notification that downloads are ready: one per film, one per show for its episodes, and
/// one per sign-in, whose downloads it's about and under which it opens them.
nonisolated struct ReadyNotice: Equatable, Sendable {
    let identifier: String
    /// The film's name, or the show's.
    let title: String
    let body: String
    /// Opens the title's page, or the show's.
    let link: URL
    /// Plays the title, or the show's earliest episode among those just ready.
    let playLink: URL
    /// Every item it covers, those of the notification it replaces included.
    let itemIds: [String]
    /// It replaces one still showing, so it comes in quietly.
    let isUpdate: Bool
    /// The poster saved for the title, which it shows.
    var poster: URL?

    /// The notification's actions, beside the tap that opens the title.
    static let categoryIdentifier = "download.ready"
    static let playAction = "play"
    static let openAction = "open"
    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryIdentifier, actions: [
            UNNotificationAction(identifier: playAction, title: "Play", options: [.foreground],
                                 icon: UNNotificationActionIcon(systemImageName: "play.fill")),
            UNNotificationAction(identifier: openAction, title: "Open", options: [.foreground],
                                 icon: UNNotificationActionIcon(systemImageName: "info.circle")),
        ], intentIdentifiers: [])
    }

    /// Where its links and items are, in the notification's user info.
    static let linkKey = "link"
    static let playLinkKey = "playLink"
    static let itemsKey = "items"
    /// How much it matters beside the app's others, for the system's summaries: more than what
    /// needs attention, which waits for the person to look.
    static let relevance = 0.9

    /// The notices for downloads just published, counting on from those still showing:
    /// `delivered` is the items each notification showing covers, by its identifier, and
    /// `posters` the poster saved for each item.
    static func notices(for jobs: [DownloadJob], delivered: [String: [String]], posters: [String: URL] = [:]) -> [ReadyNotice] {
        var groups: [(key: String, jobs: [DownloadJob])] = []
        for job in jobs {
            var key = job.isEpisode ? "ready.series.\(job.seriesId ?? job.item?.seriesName ?? job.itemId)" : "ready.item.\(job.itemId)"
            // Two people downloading one show each hear of their own episodes.
            if let owner = job.owner { key += "@\(owner.tokenKey)" }
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].jobs.append(job)
            } else {
                groups.append((key, [job]))
            }
        }
        return groups.map { key, jobs in
            let earlier = delivered[key] ?? []
            var itemIds = earlier
            for job in jobs where !itemIds.contains(job.itemId) { itemIds.append(job.itemId) }
            let last = jobs[jobs.count - 1]
            let owner = last.owner.map(AppLink.Owner.init)
            let title: String
            let body: String
            let link: URL
            var played = last
            if itemIds.count > 1, last.isEpisode, let seriesId = last.seriesId {
                title = last.item?.seriesName ?? "A Show"
                body = "\(itemIds.count) episodes are ready to watch offline."
                link = AppLink(.open, JellyfinItem(id: seriesId, name: title, type: "Series"), owner: owner).url
                played = jobs.min { episodeOrder($0).lexicographicallyPrecedes(episodeOrder($1)) } ?? last
            } else if last.isEpisode, let item = last.item {
                title = item.seriesName ?? last.title
                body = "\([item.name, item.episodeCode.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")) is ready to watch offline."
                link = AppLink(.open, item, owner: owner).url
            } else {
                title = last.title
                body = "Ready to watch offline."
                link = AppLink(.open, item(of: last), owner: owner).url
            }
            return ReadyNotice(identifier: key, title: title, body: body, link: link,
                               playLink: AppLink(.play, item(of: played), owner: owner).url, itemIds: itemIds,
                               isUpdate: delivered[key] != nil, poster: posters[last.itemId])
        }
    }

    /// The notification's content, showing `attachments`.
    func content(attachments: [UNNotificationAttachment] = []) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = identifier
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.linkKey: link.absoluteString, Self.playLinkKey: playLink.absoluteString, Self.itemsKey: itemIds]
        content.relevanceScore = Self.relevance
        content.attachments = attachments
        if isUpdate {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        return content
    }

    private static func item(of job: DownloadJob) -> JellyfinItem {
        job.item ?? JellyfinItem(id: job.itemId, name: job.title, type: job.isEpisode ? "Episode" : "Movie")
    }

    /// Where an episode comes in its show, for the earliest of several.
    private static func episodeOrder(_ job: DownloadJob) -> [Int] {
        [job.item?.parentIndexNumber ?? .max, job.item?.indexNumber ?? .max]
    }
}


/// Something about the downloads the user has to act on.
nonisolated enum DownloadAttention: Hashable, Sendable {
    case failed(UUID)
    case space(UUID)
    /// The server has been out of reach for over `unreachableLimit`.
    case unreachable

    static let unreachableLimit: TimeInterval = 60 * 60

    /// What needs attention now. The server only counts as out of reach while the device is
    /// on a network: offline, waiting says nothing about it.
    static func current(jobs: [DownloadJob], waits: [UUID: DownloadWait], isNetworkReachable: Bool, now: Date) -> Set<DownloadAttention> {
        var current: Set<DownloadAttention> = []
        for job in jobs {
            if job.status == .failed { current.insert(.failed(job.id)) }
            guard job.status == .active else { continue }
            if case .space = waits[job.id] { current.insert(.space(job.id)) }
            if isNetworkReachable, let since = job.serverUnreachableSince, now.timeIntervalSince(since) > unreachableLimit {
                current.insert(.unreachable)
            }
        }
        return current
    }

    var key: String {
        switch self {
        case .failed(let id): "failed:\(id.uuidString)"
        case .space(let id): "space:\(id.uuidString)"
        case .unreachable: "unreachable"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count == 2 ? UUID(uuidString: parts[1]) : nil) {
        case ("failed", let id?): self = .failed(id)
        case ("space", let id?): self = .space(id)
        case ("unreachable", nil) where parts.count == 1: self = .unreachable
        default: return nil
        }
    }
}

/// The one notification about what needs attention, in plain words with what to do.
nonisolated struct AttentionNotice: Equatable, Sendable {
    let title: String
    let body: String
    /// The title concerned, when it's one download.
    let link: URL?

    init(_ attention: Set<DownloadAttention>, jobs: [DownloadJob], waits: [UUID: DownloadWait], serverName: String?, hasStorageLimit: Bool) {
        var failed: [DownloadJob] = []
        var short: [(job: DownloadJob, needed: Int64)] = []
        let unreachable = attention.contains(.unreachable)
        // In list order, so the first named is the one that would download first.
        for job in jobs {
            if attention.contains(.failed(job.id)) { failed.append(job) }
            if attention.contains(.space(job.id)), case .space(let needed) = waits[job.id] { short.append((job, needed)) }
        }
        let server = serverName ?? "your server"
        var sentences: [String] = []
        if let first = failed.first {
            sentences.append(failed.count == 1
                ? "\(first.shortName) couldn't download\(first.lastError.map { ": \($0)" } ?? ".")"
                : "\(failed.count) downloads couldn't finish. Open vinnyfin to retry them.")
        }
        if let first = short.first {
            let needed = first.needed.formatted(.byteCount(style: .file))
            sentences.append(short.count == 1
                ? "\(first.job.shortName) needs \(needed) more space."
                : "\(short.count) downloads are waiting for space; the next needs \(needed) more.")
            sentences.append(StorageBudget.advice(hasLimit: hasStorageLimit))
        }
        if unreachable {
            sentences.append("vinnyfin hasn't been able to reach \(server) for over an hour. Downloads carry on once it can.")
        }
        let kinds = [!failed.isEmpty, !short.isEmpty, unreachable].count(where: \.self)
        if kinds > 1 {
            title = "Downloads Need Attention"
        } else if !failed.isEmpty {
            title = failed.count == 1 ? "Download Failed" : "Downloads Failed"
        } else if !short.isEmpty {
            title = "Not Enough Space for Downloads"
        } else {
            title = "Can't Reach \(server)"
        }
        body = sentences.joined(separator: " ")
        let only = failed.count + short.count == 1 ? (failed.first ?? short.first?.job) : nil
        link = only.map { job in
            AppLink(.open, job.item ?? JellyfinItem(id: job.itemId, name: job.title, type: job.isEpisode ? "Episode" : "Movie"),
                    owner: job.owner.map(AppLink.Owner.init)).url
        }
    }

    /// How much it matters beside the app's others, for the system's summaries: less than a
    /// title that's ready to watch.
    static let relevance = 0.5

    /// The notification's content, in `thread`.
    func content(thread: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        content.relevanceScore = Self.relevance
        if let link { content.userInfo = [ReadyNotice.linkKey: link.absoluteString] }
        return content
    }
}
#endif
