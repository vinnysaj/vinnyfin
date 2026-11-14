import AetherEngine
import Foundation
import Observation
import OSLog
import SwiftUI

/// Starts playbacks and owns the one playback engine, which is built once and reused for every
/// title, as the engine expects. On iPhone, iPad and Apple TV the player covers the app; on the
/// Mac and Vision Pro it opens in a window of its own.
@Observable
final class PlayerCoordinator {
    /// The playback on screen: the full-screen player's, or the player window's, which sets it.
    var presented: PlayerModel?
    /// A playback waiting for the root view to open its window, on the Mac and Vision Pro.
    var pendingWindowRequest: PlaybackRequest?
    #if os(macOS)
    /// Portable TV's window is open, and plays what starts, rather than a player window.
    var playsOnTV = false
    /// A playback waiting for Portable TV's window to show it.
    var pendingTVRequest: PlaybackRequest?
    /// How loud the engine plays, from nothing to 1. Portable TV turns it down where the Mac has
    /// no volume of its own to turn down.
    @ObservationIgnored var volume: Float = 1 {
        didSet { engine?.volume = volume }
    }
    #endif
    #if os(visionOS)
    /// The playback is on the cinema's big screen, in its immersive space, rather than in its window.
    var isInCinema = false
    /// RealityKit is drawing the picture in 3D.
    var pictureIsStereo = false
    /// Pinches on RealityKit's screen, in the window or the cinema, counted: the player window shows
    /// or hides its controls on each.
    var screenTaps = 0
    #endif
    /// Why the engine couldn't be built, to show instead of playing.
    var problem: String?
    /// A playback another device asked to stop, which its player closes.
    var stopRequest: PlayerModel.ID?
    /// Offers to watch what starts with the people on a FaceTime call.
    @ObservationIgnored weak var sharePlay: SharePlay?
    /// What the last player to close played, once the server has heard it stop: pages showing a
    /// title's watch state load it again, and lists put it on their cards.
    private(set) var endedPlayback = EndedPlayback()

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    /// The player covers the app's screens, as it does on iPhone, iPad and Apple TV while it's
    /// presented, but for while it's put away in Picture in Picture. On the Mac and Vision Pro it
    /// plays in a window of its own.
    var coversScreens: Bool {
        #if os(macOS) || os(visionOS)
        false
        #else
        presented != nil && !isInPictureInPicture
        #endif
    }

    /// On iPhone and iPad, the player is put away while its playback plays in Picture in Picture,
    /// so the app can be browsed meanwhile; `presented` keeps the playback. The window's restore
    /// button brings the player back, and its close button ends the playback.
    private(set) var isInPictureInPicture = false

    /// The playback the full-screen player shows: `presented`, but for while it plays in Picture
    /// in Picture with the player put away.
    var coverModel: PlayerModel? {
        get { isInPictureInPicture ? nil : presented }
        set { if newValue == nil, !isInPictureInPicture { presented = nil } }
    }

    #if os(iOS) || os(macOS)
    /// Picture in Picture, for the playback on screen; kept here, so the window outlives a player
    /// put away while it plays.
    let pictureInPicture = PictureInPicture()
    /// The window's restore, waiting for the player to be back on screen to take the picture.
    @ObservationIgnored private var pendingRestore: ((Bool) -> Void)?
    #endif

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private var engine: AetherEngine?
    @ObservationIgnored private let lease = EngineLease()
    #if !os(tvOS)
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let smartDownloads: SmartDownloads
    @ObservationIgnored private let localLibrary: LocalLibrary

    init(accounts: AccountStore, settings: AppSettings, history: WatchHistory,
         downloads: DownloadManager, smartDownloads: SmartDownloads, localLibrary: LocalLibrary) {
        self.accounts = accounts
        self.settings = settings
        self.history = history
        self.downloads = downloads
        self.smartDownloads = smartDownloads
        self.localLibrary = localLibrary
        #if os(iOS) || os(macOS)
        followPictureInPicture()
        #endif
    }
    #else
    init(accounts: AccountStore, settings: AppSettings, history: WatchHistory) {
        self.accounts = accounts
        self.settings = settings
        self.history = history
    }
    #endif

    /// Plays what the viewer picked. On a FaceTime call it first asks whether to watch it with
    /// everyone on the call.
    func play(_ request: PlaybackRequest) {
        guard let sharePlay else { return open(request) }
        Task {
            switch await sharePlay.offer(request) {
            case .playHere: open(request)
            // The group's session opens it, here as everywhere.
            case .playTogether, .cancelled: break
            }
        }
    }

    /// Plays without asking: for what another device or the group asks for.
    func open(_ request: PlaybackRequest) {
        #if os(macOS)
        if playsOnTV { pendingTVRequest = request } else { pendingWindowRequest = request }
        #elseif os(visionOS)
        pendingWindowRequest = request
        #else
        Task { await present(request) }
        #endif
    }

    /// Does what another device asked, through Jellyfin's remote control, as if the viewer here did.
    func perform(_ command: RemoteCommand) {
        if case .play(let itemId, let start, let mediaSourceId, let audioStreamIndex, let subtitleStreamIndex) = command {
            open(PlaybackRequest(source: .item(id: itemId, mediaSourceId: mediaSourceId), title: "",
                                 startingPoint: .init(position: start, audioStreamIndex: audioStreamIndex,
                                                      subtitleStreamIndex: subtitleStreamIndex)))
            return
        }
        // The rest are for what's playing; the server sends them only to a session that plays.
        guard let model = presented else { return }
        switch command {
        // Portable TV's, which takes them before they get here while it shows.
        case .play, .tv: break
        case .pause: model.pause()
        case .unpause: model.play()
        case .togglePause: model.togglePlayPause()
        // Put away, the player isn't there to close itself.
        case .stop where isInPictureInPicture: Task { await dismiss() }
        case .stop: stopRequest = model.id
        case .seek(let seconds): model.seek(to: seconds)
        case .skip(let seconds): model.skip(by: seconds)
        case .nextEpisode: Task { await model.playNextEpisode() }
        case .previousEpisode: Task { await model.playPreviousEpisode() }
        case .audioStream(let index): model.chooseAudio(streamIndex: index)
        case .subtitleStream(let index): model.chooseSubtitle(streamIndex: index)
        }
    }

    /// Plays a file the user picked, remembering it among the recent files. The caller holds
    /// access to the file while this runs.
    func playFile(_ url: URL) {
        do {
            let request = try PlaybackRequest.file(url)
            #if !os(tvOS)
            localLibrary.noteOpened(url, request: request)
            #endif
            play(request)
        } catch {
            problem = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func present(_ request: PlaybackRequest) async {
        // One engine plays one thing: what plays in Picture in Picture ends too.
        await dismiss()
        presented = makeModel(for: request)
    }

    func dismiss() async {
        guard let model = presented else { return }
        presented = nil
        isInPictureInPicture = false
        #if os(iOS) || os(macOS)
        pictureInPicture.close()
        pendingRestore?(false)
        pendingRestore = nil
        #endif
        await model.close()
    }

    #if os(iOS) || os(macOS)
    private func followPictureInPicture() {
        pictureInPicture.onStart = { [weak self] in self?.pictureInPictureStarted() }
        pictureInPicture.onRestore = { [weak self] done in
            guard let self else { return done(false) }
            self.restoreFromPictureInPicture(done)
        }
        pictureInPicture.onClose = { [weak self] in self?.pictureInPictureClosed() }
    }

    /// On iPhone and iPad the player is put away once the window has the picture.
    private func pictureInPictureStarted() {
        #if os(iOS)
        guard presented != nil else { return }
        isInPictureInPicture = true
        #endif
    }

    /// The window's restore button: the player comes back at once, without its slide, as the
    /// window flies back into it, and takes the picture back once it's on screen.
    private func restoreFromPictureInPicture(_ done: @escaping (Bool) -> Void) {
        guard isInPictureInPicture, presented != nil else { return done(presented != nil) }
        pendingRestore?(false)
        pendingRestore = done
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { isInPictureInPicture = false }
    }

    /// The player is on screen: a restore waiting for it completes.
    func playerAppeared() {
        pendingRestore?(true)
        pendingRestore = nil
    }

    /// The window's own close button ends the playback, its player put away.
    private func pictureInPictureClosed() {
        guard isInPictureInPicture else { return }
        Task { await dismiss() }
    }
    #endif

    /// A model for `request`, on the shared engine. Nil when the engine can't be built.
    func makeModel(for request: PlaybackRequest) -> PlayerModel? {
        guard let engine = sharedEngine() else { return nil }
        #if os(tvOS)
        let resolver = PlaybackResolver(accounts: accounts, settings: settings, history: history) { _, _ in nil }
        let model = PlayerModel(request: request, engine: engine, lease: lease, resolver: resolver, accounts: accounts,
                                history: history, settings: settings) { _ in nil }
        #else
        let resolver = PlaybackResolver(accounts: accounts, settings: settings, history: history) { [downloads] itemId, mediaSourceId in
            downloads.playableFile(itemId: itemId, mediaSourceId: mediaSourceId)
        }
        let model = PlayerModel(request: request, engine: engine, lease: lease, resolver: resolver, accounts: accounts,
                                history: history, settings: settings) { [downloads] episode in
            downloads.downloadedEpisode(after: episode)
        }
        // Downloads wait while something plays, and smart downloads while the player is open.
        let id = model.id
        downloads.playerChanged(id, isPlaying: true)
        smartDownloads.playerOpened(id)
        model.onUnderwayChanged = { [downloads, weak model] underway in
            downloads.playerChanged(id, isPlaying: underway, isTranscoding: model?.isTranscoding ?? false)
        }
        #endif
        model.onClose = { [weak self, weak model] in
            #if !os(tvOS)
            self?.downloads.playerClosed(id)
            self?.smartDownloads.playerClosed(id)
            #endif
            let reported = model?.stopReport
            let played = model?.playedTitleIds ?? []
            Task {
                await reported?.value
                await self?.endPlayback(of: played)
            }
        }
        return model
    }

    /// Asks the server for the watch state of what was played, here or on a device this one was
    /// the remote for. A title it can't be asked about keeps the state its cards show until they
    /// load again. The Up Next widgets ask the server for theirs again.
    func endPlayback(of titleIds: Set<String>) async {
        #if os(iOS) || os(macOS)
        if !titleIds.isEmpty { UpNextWidgets.reload() }
        #endif
        var userData: [String: UserItemData] = [:]
        if let client = accounts.client, let account = accounts.account {
            let userId = account.userId
            await withTaskGroup(of: (String, Result<UserItemData, any Error>).self) { group in
                for id in titleIds {
                    group.addTask { (id, await Result { try await client.userData(itemId: id, userId: userId) }) }
                }
                for await (id, result) in group {
                    switch result {
                    case .success(let data): userData[id] = data
                    case .failure(let error):
                        Self.log.notice("Couldn't load the watch state of \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        endedPlayback = EndedPlayback(count: endedPlayback.count + 1, userData: userData)
    }

    private func sharedEngine() -> AetherEngine? {
        if let engine { return engine }
        do {
            let engine = try AetherEngine()
            // The player draws its own controls, so the engine owns the system's Now Playing
            // card and remote commands on both of its decode paths.
            #if os(iOS) || os(tvOS)
            engine.ownsVideoNowPlayingSession = true
            #endif
            engine.ownsSoftwareNowPlaying = true
            engine.remoteSkipInterval = PlayerModel.skipInterval
            #if os(macOS)
            engine.volume = volume
            #endif
            self.engine = engine
            return engine
        } catch {
            problem = "The player couldn't start: \(error.localizedDescription)"
            return nil
        }
    }
}

/// A player that closed: the watch state of what it played, as the server has it.
nonisolated struct EndedPlayback: Equatable, Sendable {
    /// Counts the players closed, so the same titles played again still change it.
    var count = 0
    /// By id: the titles played, and the shows of the episodes among them.
    var userData: [String: UserItemData] = [:]

    /// `item` with the watch state the playback left it in.
    func applied(to item: JellyfinItem) -> JellyfinItem {
        guard let data = userData[item.id] else { return item }
        var updated = item
        updated.userData = data
        return updated
    }

    func applied(to items: [JellyfinItem]) -> [JellyfinItem] {
        items.map(applied(to:))
    }
}
