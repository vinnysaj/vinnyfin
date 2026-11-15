import SwiftUI

/// The long-press menu for a title: play, its show for an episode, watched, favourite and, off
/// Apple TV, download. A show's plays its next episode, or shuffles its episodes. For a card that
/// plays on a tap, it leads with the title's page instead.
struct ItemContextMenu: View {
    let item: JellyfinItem
    /// The card plays the title on a tap, as Continue Watching's do, so the menu leads with
    /// Details, Go to Show and Start Over rather than playing it again.
    var playsOnTap = false
    /// Gets the item with its new watch state, to update the list it came from.
    var onChange: (JellyfinItem) -> Void = { _ in }

    @Environment(\.session) private var session
    @Environment(\.openTitle) private var openTitle
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    #endif

    var body: some View {
        if playsOnTap {
            if let openTitle {
                Button("Details", systemImage: "info.circle") { openTitle(item) }
            }
            goToShow
            startOver
        } else {
            if item.isPlayable {
                Button(item.resumeSeconds != nil ? "Resume" : "Play", systemImage: "play.fill") {
                    player.play(.item(item))
                }
            }
            if item.isSeries { showPlayback }
            startOver
            goToShow
        }
        // As the title's page has it.
        Button(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched",
               systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle") {
            Task { await setPlayed(!item.isPlayed) }
        }
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: item.isFavorite ? "heart.slash" : "heart") {
            Task { await setFavorite(!item.isFavorite) }
        }
        #if !os(tvOS)
        if item.isMovie || item.isEpisode {
            if downloads.isDownloaded(item.id) {
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    downloads.deleteDownloads(ofItem: item.id)
                }
            } else if downloads.jobs(forItem: item.id).isEmpty {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task { await download() }
                }
            }
        }
        if item.isSeries {
            // The show's own Download menu's choices, but for Every Unwatched Episode, which first
            // says how much it takes in a dialog a long-press menu can't hold.
            Menu("Keep Downloaded", systemImage: "sparkles") {
                SmartDownloadCounts(seriesId: item.id, seriesName: item.name)
                if smartDownloads.rule(for: item.id) != nil {
                    StopSmartDownloads(seriesId: item.id)
                }
            }
        }
        #endif
    }

    /// A show's next episode, as its page's Play has it, and Shuffle. The menu can't wait for the
    /// next episode to name it, so it says what kind of play it is.
    @ViewBuilder private var showPlayback: some View {
        Button(ShowPlayback.menuTitle(for: item), systemImage: item.isPlayed ? "arrow.counterclockwise" : "play.fill") {
            guard let session else { return }
            Task { await ShowPlayback.playNext(of: item, session: session, player: player, messages: messages) }
        }
        Button("Shuffle", systemImage: "shuffle") {
            guard let session else { return }
            Task { await ShowPlayback.shuffle(item, session: session, player: player, messages: messages) }
        }
    }

    /// As the title's page has it.
    @ViewBuilder private var startOver: some View {
        if item.isPlayable, item.resumeSeconds != nil {
            Button("Start Over", systemImage: "arrow.counterclockwise") {
                player.play(.item(item, fromBeginning: true))
            }
        }
    }

    @ViewBuilder private var goToShow: some View {
        if item.isEpisode, let seriesId = item.seriesId, let openTitle {
            Button("Go to Show", systemImage: "tv") {
                openTitle(JellyfinItem(id: seriesId, name: item.seriesName ?? "", type: "Series"))
            }
        }
    }

    private func setPlayed(_ played: Bool) async {
        guard let session else { return }
        if WatchActions.marksManyEpisodes(item) {
            await WatchActions.setPlayedAfterAsking(played, on: item, session: session, messages: messages, onChange: onChange)
        } else {
            await WatchActions.setPlayed(played, on: item, session: session, messages: messages, onChange: onChange)
        }
    }

    private func setFavorite(_ favorite: Bool) async {
        guard let session else { return }
        await WatchActions.setFavorite(favorite, on: item, session: session, messages: messages, onChange: onChange)
    }

    #if !os(tvOS)
    private func download() async {
        guard let session else { return }
        do {
            let detail = try await session.client.item(id: item.id, userId: session.userId)
            if let problem = await downloads.download(detail, settings: settings) { messages.show(problem) }
        } catch {
            messages.show("Couldn't start the download of \(item.name): \(error.localizedDescription)")
        }
    }
    #endif
}

/// Marks the episodes of a show before this one watched, those not yet (`WatchSnapshot.previous`),
/// and offers Undo: for an episode's menu in a list that shows the change, on its show's page and
/// on its own. The first episode, or a special, has none before it to mark.
struct MarkPreviousWatchedButton: View {
    let episode: JellyfinItem
    /// Called once the episodes are marked, and again once Undo has put them back.
    let afterChange: () async -> Void
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages

    var body: some View {
        if episode.isEpisode, let season = episode.parentIndexNumber, season > 0, season > 1 || (episode.indexNumber ?? 0) > 1 {
            Button("Mark Previous as Watched", systemImage: "checklist.checked") {
                guard let session else { return }
                Task {
                    await WatchActions.markPreviousWatched(before: episode, session: session, messages: messages, afterChange: afterChange)
                }
            }
        }
    }
}

/// Watched and favourite changes: shown at once, sent to the server, undone if it refuses. A
/// change to many episodes at once keeps what each was first, so Undo can put every one back as
/// it was: a whole show's or season's, which asks first, as one press of it rewrites what of the
/// show was watched, and those before an episode or picked together, which don't.
enum WatchActions {
    /// Returns whether the server took the change.
    @discardableResult
    static func setPlayed(_ played: Bool, on item: JellyfinItem, session: ServerSession, messages: AppMessages,
                          onChange: (JellyfinItem) -> Void) async -> Bool {
        var updated = item
        var data = item.userData ?? UserItemData()
        data.played = played
        data.playbackPositionTicks = 0
        data.playedPercentage = nil
        if item.isSeries || item.isSeason { data.unplayedItemCount = played ? 0 : nil }
        updated.userData = data
        onChange(updated)
        do {
            try await session.client.setPlayed(played, itemId: item.id, userId: session.userId)
            return true
        } catch {
            onChange(item)
            messages.show("Couldn't update \(item.name): \(error.localizedDescription)")
            return false
        }
    }

    static func setFavorite(_ favorite: Bool, on item: JellyfinItem, session: ServerSession, messages: AppMessages,
                            onChange: (JellyfinItem) -> Void) async {
        var updated = item
        var data = item.userData ?? UserItemData()
        data.isFavorite = favorite
        updated.userData = data
        onChange(updated)
        do {
            try await session.client.setFavorite(favorite, itemId: item.id, userId: session.userId)
        } catch {
            onChange(item)
            messages.show("Couldn't update \(item.name): \(error.localizedDescription)")
        }
    }

    /// Whether marking `item` watched or unwatched marks every episode of it: a show or a season.
    nonisolated static func marksManyEpisodes(_ item: JellyfinItem) -> Bool {
        item.isSeries || item.isSeason
    }

    /// Marks a whole show or season watched or unwatched once the question saying how many episodes
    /// that is has been answered, then offers Undo. `afterChange` runs once the server has the
    /// change, and again once Undo has put the episodes back, for what the page shows of them.
    static func setPlayedAfterAsking(_ played: Bool, on item: JellyfinItem, session: ServerSession, messages: AppMessages,
                                     onChange: @escaping (JellyfinItem) -> Void,
                                     afterChange: @escaping () async -> Void = {}) async {
        // What each episode was, taken as the question is asked: without it there's no Undo.
        let episodes = try? await episodes(of: item, session: session)
        let wording = WatchChangeWording(item: item, played: played, episodes: episodes?.count)
        messages.ask(Confirmation(title: wording.question, message: wording.consequence, action: wording.action) {
            Task {
                guard await setPlayed(played, on: item, session: session, messages: messages, onChange: onChange) else { return }
                await afterChange()
                guard let episodes else { return }
                offerUndo(of: WatchSnapshot(episodes), marking: played, title: wording.done, detail: wording.subject,
                          session: session, messages: messages) {
                    onChange(item)
                    await afterChange()
                }
            }
        })
    }

    /// Marks `episodes` of a show watched or unwatched, those not already so, and offers Undo.
    static func setPlayed(_ played: Bool, episodes: [JellyfinItem], showName: String, session: ServerSession,
                          messages: AppMessages, afterChange: @escaping () async -> Void) async {
        let changing = episodes.filter { $0.isPlayed != played }
        guard !changing.isEmpty else { return }
        do {
            try await forEach(changing.map(\.id)) { try await session.client.setPlayed(played, itemId: $0, userId: session.userId) }
        } catch {
            messages.show("Couldn't mark the episodes of \(showName) as \(played ? "watched" : "unwatched"): \(error.localizedDescription)")
        }
        await afterChange()
        offerUndo(of: WatchSnapshot(changing), marking: played, title: WatchChangeWording.done(played: played, count: changing.count),
                  detail: showName, session: session, messages: messages, afterUndo: afterChange)
    }

    /// Marks the episodes of `episode`'s show before it watched, as `WatchSnapshot.previous` picks
    /// them, and offers Undo.
    static func markPreviousWatched(before episode: JellyfinItem, session: ServerSession, messages: AppMessages,
                                    afterChange: @escaping () async -> Void) async {
        guard let seriesId = episode.seriesId else { return }
        let showName = episode.seriesName ?? episode.name
        do {
            let all = try await session.client.episodes(seriesId: seriesId, seasonId: nil, userId: session.userId,
                                                        fields: JellyfinClient.cardFields, missing: false)
            let previous = WatchSnapshot.previous(before: episode, in: all, now: .now)
            guard !previous.isEmpty else { return }
            await setPlayed(true, episodes: previous, showName: showName, session: session, messages: messages, afterChange: afterChange)
        } catch {
            guard !error.isCancellation else { return }
            messages.show("Couldn't load the episodes of \(showName): \(error.localizedDescription)")
        }
    }

    /// The episodes a show or season marked watched or unwatched marks, as they are now.
    private static func episodes(of item: JellyfinItem, session: ServerSession) async throws -> [JellyfinItem] {
        let seriesId = item.isSeries ? item.id : (item.seriesId ?? item.id)
        return try await session.client.episodes(seriesId: seriesId, seasonId: item.isSeason ? item.id : nil, userId: session.userId,
                                                 fields: JellyfinClient.cardFields, missing: false)
    }

    private static func offerUndo(of snapshot: WatchSnapshot, marking played: Bool, title: String, detail: String,
                                  session: ServerSession, messages: AppMessages, afterUndo: @escaping () async -> Void) {
        let restores = snapshot.restoring(afterMarking: played)
        guard !restores.isEmpty else { return }
        messages.offerUndo(UndoOffer(title: title, detail: detail, announcement: "\(title): \(detail)") {
            Task {
                do {
                    try await restore(restores, session: session)
                } catch {
                    messages.show("Couldn't put the episodes of \(detail) back as they were: \(error.localizedDescription)")
                }
                await afterUndo()
            }
        })
    }

    private static func restore(_ restores: [WatchSnapshot.Restore], session: ServerSession) async throws {
        let client = session.client
        let userId = session.userId
        try await forEach(restores) { restore in
            switch restore {
            case .unwatched(let itemId):
                try await client.setPlayed(false, itemId: itemId, userId: userId)
            case .userData(let itemId, let update):
                try await client.updateUserData(itemId: itemId, userId: userId, update)
            }
        }
    }

    /// Runs `work` on each element, a few at a time.
    private static func forEach<Element: Sendable>(_ elements: [Element],
                                                   _ work: @escaping @Sendable (Element) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = elements[...]
            for _ in 0..<min(6, pending.count) {
                guard let next = pending.popFirst() else { break }
                group.addTask { try await work(next) }
            }
            while try await group.next() != nil {
                guard let next = pending.popFirst() else { continue }
                group.addTask { try await work(next) }
            }
        }
    }
}

/// What a set of episodes' watch states were before a change to all of them, and what puts each
/// back as it was.
nonisolated struct WatchSnapshot: Equatable, Sendable {
    /// Putting one episode back.
    enum Restore: Equatable, Sendable {
        /// Never played, or begun: marked unwatched, which also forgets when it was played.
        case unwatched(String)
        /// As it was saved: watched or not, where it was left, how many times and when last it was played.
        case userData(String, UserDataUpdate)
    }

    /// Each episode's state, in the show's order.
    let states: [(id: String, data: UserItemData)]

    init(_ episodes: [JellyfinItem]) {
        states = episodes.map { ($0.id, $0.userData ?? UserItemData()) }
    }

    static func == (left: WatchSnapshot, right: WatchSnapshot) -> Bool {
        left.states.map(\.id) == right.states.map(\.id) && left.states.map(\.data) == right.states.map(\.data)
    }

    /// What puts back each episode a marking of them all `played` changed. Marking watched changes
    /// every one, as it dates each play; marking unwatched only those with something of being
    /// watched to lose. An episode nothing of had been played goes back to unwatched, which the
    /// server dates nothing, rather than to its saved state, which can't take a date away.
    func restoring(afterMarking played: Bool) -> [Restore] {
        states.compactMap { id, data in
            let untouched = data.played != true && (data.playbackPositionTicks ?? 0) == 0 && (data.playCount ?? 0) == 0
                && data.lastPlayedDate == nil
            if untouched { return played ? .unwatched(id) : nil }
            return .userData(id, UserDataUpdate(restoring: data))
        }
    }

    /// The episodes of a show before `episode`, from all of them in order, that Mark Previous as
    /// Watched marks: those the player goes through (no specials, nothing not out yet) not watched yet.
    static func previous(before episode: JellyfinItem, in episodes: [JellyfinItem], now: Date) -> [JellyfinItem] {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return [] }
        return episodes[..<index].filter { !$0.isPlayed && UpNext.canGoOn(to: $0, now: now) }
    }
}

/// What the question before marking a whole show or season says, and the toast after it.
nonisolated struct WatchChangeWording: Equatable {
    let item: JellyfinItem
    let played: Bool
    /// How many episodes it marks, when that's known.
    let episodes: Int?

    /// "Mark Port Ellery as Watched?", "Mark Season 2 as Unwatched?"
    var question: String { "Mark \(item.name) as \(state)?" }

    /// "All 12 episodes will be marked as watched." Of a season, whose name doesn't say its show,
    /// with the show's:
    /// "All 6 episodes of Season 2 of Port Ellery will be marked as unwatched."
    var consequence: String {
        let of = item.isSeason ? " of \(item.name)\(item.seriesName.map { " of \($0)" } ?? "")" : ""
        let which = switch episodes {
        case 1?: "Its one episode\(of)"
        case let count?: "All \(count) episodes\(of)"
        case nil: "Every episode\(of)"
        }
        return "\(which) will be marked as \(state.lowercased())."
    }

    /// The question's button.
    var action: String { "Mark as \(state)" }

    /// The toast's title once it's done.
    var done: String { "Marked as \(state)" }

    /// What the toast names: "Port Ellery", "Port Ellery · Season 2".
    var subject: String {
        guard item.isSeason, let show = item.seriesName else { return item.name }
        return "\(show) · \(item.name)"
    }

    private var state: String { played ? "Watched" : "Unwatched" }

    /// The toast's title once `count` episodes picked are marked: "Marked 3 Episodes as Watched".
    static func done(played: Bool, count: Int) -> String {
        "Marked \(count == 1 ? "1 Episode" : "\(count) Episodes") as \(played ? "Watched" : "Unwatched")"
    }
}
