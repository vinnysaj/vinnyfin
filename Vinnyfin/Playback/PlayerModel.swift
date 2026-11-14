import AetherEngine
import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Nuke
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The playhead, ten times a second. Kept apart from `PlayerModel` so only the views that show
/// time redraw that often.
@Observable
final class PlaybackClock {
    var time: Double = 0
    /// The media's own timestamp of the frame on screen, which subtitle cues are timed against.
    var sourceTime: Double = 0
    var buffered: Double = 0
}

/// Which playback holds the shared engine. A player that is closing stops the engine only if it
/// still holds it, so it can't stop the playback that replaced it.
final class EngineLease {
    var holder: UUID?
}

/// The one load a player has under way: resolving a title, asking the server for a new stream,
/// and starting it in the engine. Starting a load cancels the one before and numbers the new
/// one. Its work checks its number after each wait and stops when another load has started
/// since: a cancelled request doesn't always end at once, and what a replaced load did after it
/// came back would undo the newer one.
final class LoadSequence {
    private(set) var generation = 0
    private var task: Task<Void, Never>?

    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Runs `work` as the load under way, given its generation, until it ends or another load
    /// replaces it. Cancelling the caller cancels it too.
    func start(_ work: @escaping (_ generation: Int) async -> Void) async {
        generation += 1
        let generation = generation
        task?.cancel()
        let task = Task { await work(generation) }
        self.task = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Stops the load under way, if there is one, for good.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}

/// The countdown to the next episode, from the start of the credits the server marks or from the
/// end of the episode, and what it was started for. It runs while the episode plays or has ended,
/// and waits while it's paused. When it runs out it plays the next episode only if nothing has
/// loaded since, the episode it started in is still on screen and still in its credits or ended,
/// and the next episode is still the one it counted down to: a Play Again, a move back on the
/// timeline or another episode picked during it plays instead.
struct UpNextCountdown: Equatable {
    /// Seconds from the start of the credits.
    static let fromCredits = 10
    /// Seconds from the end of an episode with no credits marked.
    static let fromEnd = 5

    let generation: Int
    let episodeId: String?
    let nextEpisodeId: String
    /// Started as the credits started, rather than at the end.
    let startedInCredits: Bool
    /// Seconds in all.
    let length: Int
    var remaining: Int

    init(generation: Int, episodeId: String?, nextEpisodeId: String, startedInCredits: Bool) {
        self.generation = generation
        self.episodeId = episodeId
        self.nextEpisodeId = nextEpisodeId
        self.startedInCredits = startedInCredits
        length = startedInCredits ? Self.fromCredits : Self.fromEnd
        remaining = length
    }

    /// How much of it has run, from 0 to 1, for the ring that fills around Play Now.
    var progress: Double {
        Double(length - remaining) / Double(length)
    }

    /// `isEnding`: the episode on screen is in its credits, or has ended.
    func isDue(loads: LoadSequence, onScreen episodeId: String?, next nextId: String?, isEnding: Bool) -> Bool {
        isEnding && loads.isCurrent(generation) && episodeId == self.episodeId && nextId == nextEpisodeId
    }
}

/// A word over the picture for a few seconds of playback, with the way back from something the
/// player did by itself.
enum PlaybackChip: Equatable {
    /// It started at the title's saved position, a moment before it; Start Over plays it from
    /// the beginning.
    case resumed(at: Double)
    /// It skipped the intro, as Skip Intros has it; Watch It goes back to it.
    case skippedIntro(MediaSegment)
}

/// A word about the playback over the picture for a few seconds, such as a move to a lower
/// quality, and what it's about.
struct PlaybackNotice: Equatable {
    enum Kind {
        /// The connection, and the quality it carries.
        case connection
        /// Something another device asked for.
        case remoteRequest
        /// Anything else, such as extras that didn't load.
        case info
    }

    let text: String
    let kind: Kind
}

/// A title's picture for the system's Now Playing: decoded once and handed to MediaPlayer, which
/// asks for it from threads of its own, and as JPEG for AVKit's info pane and AirPlay receivers.
struct NowPlayingArtwork {
    let itemId: String
    let artwork: MPMediaItemArtwork
    let jpeg: Data?

    init(itemId: String, image: PlatformImage) {
        self.itemId = itemId
        artwork = Self.artwork(of: DecodedImage(image: image))
        #if canImport(UIKit)
        jpeg = image.jpegData(compressionQuality: 0.8)
        #else
        jpeg = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #endif
    }

    /// Made where nothing is isolated, so MediaPlayer can call it from any thread.
    nonisolated private static func artwork(of picture: DecodedImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: picture.image.size) { _ in picture.image }
    }

    /// An image decoded already and never changed, which any thread can read.
    private nonisolated struct DecodedImage: @unchecked Sendable {
        let image: PlatformImage
    }
}

/// One audio or subtitle choice in the player's menus.
struct TrackOption: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String?
}

/// A playback on screen: what it is, how it's going, and the commands for it. Drives the shared
/// engine, tells the server how far playback got, and keeps the position for offline use.
@Observable
final class PlayerModel: Identifiable {
    let id = UUID()

    enum Status: Equatable {
        case preparing
        case loading
        case playing
        case paused
        case buffering
        case ended
        case failed(String)

        /// Getting ready to play or playing: the picture needs the connection.
        var isUnderway: Bool {
            switch self {
            case .preparing, .loading, .playing, .buffering: true
            case .paused, .ended, .failed: false
            }
        }
    }

    private(set) var status = Status.preparing {
        didSet {
            if status.isUnderway != oldValue.isUnderway { onUnderwayChanged?(status.isUnderway) }
            if case .failed(let message) = status { failure = message }
        }
    }
    private(set) var title: String
    private(set) var subtitle: String?
    /// The playback on screen: the stream playing, or once it has ended or failed, that one still,
    /// whose title, chapters, previews and versions the controls go on showing. A new title clears
    /// it as it starts loading.
    private(set) var current: ResolvedPlayback?
    private(set) var duration: Double = 0
    private(set) var videoFormat = VideoFormat.sdr
    /// The picture's shape in display pixels, for placing picture subtitles.
    private(set) var videoSize: CGSize?
    private(set) var audioOptions: [TrackOption] = []
    private(set) var subtitleOptions: [TrackOption] = []
    private(set) var selectedAudio: Int?
    private(set) var selectedSubtitle: Int?
    private(set) var cues: [SubtitleCue] = []
    private(set) var nextEpisode: JellyfinItem?
    private(set) var segments: [MediaSegment] = []
    private(set) var rate: Float = 1
    /// The countdown to the next episode starting by itself; nil when it isn't counting down.
    private(set) var upNextCountdown: UpNextCountdown?
    /// After `UnattendedAutoplay.limit` episodes started by themselves with nobody doing anything,
    /// the player asks whether anyone is still watching, paused, rather than counting down.
    private(set) var asksStillWatching = false
    /// A word about the playback, such as a move to a lower quality, shown for a few seconds.
    private(set) var notice: PlaybackNotice?
    /// Says it resumed, or skipped the intro, with the way back, for a few seconds.
    private(set) var chip: PlaybackChip?
    /// Titles like the one that ended, for its end screen when nothing comes after it.
    private(set) var similarTitles: [JellyfinItem] = []
    /// Try Again was pressed a moment ago. The failure stays up meanwhile, saying so, rather than
    /// flashing away and back when the new try fails at once.
    private(set) var isRetrying = false
    /// The viewer hid the up-next card, or stopped its countdown, for the episode on screen.
    private(set) var upNextDismissed = false
    let clock = PlaybackClock()
    /// The position the viewer is moving the timeline to, before it's committed.
    let scrubbing = Scrubbing()
    let engine: AetherEngine

    @ObservationIgnored private let resolver: PlaybackResolver
    @ObservationIgnored private let lease: EngineLease
    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private let settings: AppSettings
    /// Finds a downloaded episode to play next when the server can't be reached.
    @ObservationIgnored private let downloadedEpisode: (_ after: JellyfinItem) -> JellyfinItem?
    /// Told when playback starts or stops being underway; a new model starts out underway.
    @ObservationIgnored var onUnderwayChanged: ((Bool) -> Void)?
    /// Told once, when the player closes for good.
    @ObservationIgnored var onClose: (() -> Void)?
    /// The group watching this together, through SharePlay, which the viewer's changes go through.
    @ObservationIgnored weak var sharing: (any PlaybackSharing)?

    @ObservationIgnored private var request: PlaybackRequest
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private let loads = LoadSequence()
    /// `current` is playing, or getting ready to, as a session the server has been told of: from
    /// `begin` until `finishSession`.
    @ObservationIgnored private var sessionIsOpen = false
    /// The viewer paused the playback while it started, or a stream of the title replaces one
    /// paused: it starts paused, and stays so through its first picture until played.
    @ObservationIgnored private var startsPaused = false
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    /// The next episode with its versions, fetched as the up-next card comes up so it starts
    /// sooner, and the warming of its stream.
    @ObservationIgnored private var preparedNext: JellyfinItem?
    @ObservationIgnored private var nextPreparation: Task<Void, Never>?
    /// Waiting to see whether a seek lands before the player shows it's waiting for one.
    @ObservationIgnored private var seekWait: Task<Void, Never>?
    /// The picture of what plays, for the system's Now Playing, by the item it's of.
    @ObservationIgnored private var nowPlayingArtwork: NowPlayingArtwork?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Where the picture is besides the app's own view, where the subtitle overlay can't follow.
    @ObservationIgnored private var pictureOutside: Set<PictureOutside> = []
    /// The system draws the subtitles, into the picture outside the app, and the overlay none.
    @ObservationIgnored private var systemDrawsSubtitles = false
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var appliedSubtitlePreference = false
    /// The engine's load returned, so its track lists are complete.
    @ObservationIgnored private var isLoaded = false
    /// The stream's first frame is on screen, or it has none to show. Until then a playing engine
    /// reads as loading: its clock and sound can run for seconds ahead of the picture, as when a
    /// start far from a keyframe is decoded in software.
    @ObservationIgnored private var isPresenting = false
    @ObservationIgnored private var lastReportedPaused: Bool?
    @ObservationIgnored private var startedReporting = false
    /// Telling the server that the last session stopped, and giving the title its position.
    @ObservationIgnored private(set) var stopReport: Task<Void, Never>?
    /// The server's titles played here, and the shows of the episodes among them, whose watch
    /// state the playback changed.
    @ObservationIgnored private(set) var playedTitleIds: Set<String> = []
    /// The title whose next episode was asked for, and the version whose segments and chapters.
    @ObservationIgnored private var extrasRequestedFor: ExtrasKey?
    /// The audio and subtitles chosen in the version this one stands in for.
    @ObservationIgnored private var carriedTracks: TrackSelection?
    /// The audio and subtitles of the version playing, as last seen on.
    @ObservationIgnored private var playingTracks: TrackSelection?
    @ObservationIgnored private var connectionWatch = ConnectionWatch()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    /// The streams the request asks to start with, until the playback it started has them.
    @ObservationIgnored private var askedStreams: PlaybackRequest.StartingPoint?
    /// The audio and subtitles the viewer picked this session, in the show they were picked in,
    /// which its other episodes start with.
    @ObservationIgnored private var sessionPicks: ShowPicks?
    /// The episodes that started by themselves since the viewer last did anything.
    @ObservationIgnored private var unattended = UnattendedAutoplay()
    /// The episode on screen started by moving on from the one before, as Next, Play Now and the
    /// countdown do, which Skip Intros' When Watching in a Row goes by.
    @ObservationIgnored private var startedInARow = false
    /// The starts of the intros the playhead has reached in the title, each skipped by itself at
    /// most once: Watch It goes back to one for good.
    @ObservationIgnored private var reachedIntros: Set<Double> = []
    @ObservationIgnored private var chipTask: Task<Void, Never>?
    @ObservationIgnored private var similarTask: Task<Void, Never>?
    /// The title's next episode was looked for, found or not: nil `nextEpisode` means it has none.
    @ObservationIgnored private var lookedForNextEpisode = false
    @ObservationIgnored private var retryHoldTask: Task<Void, Never>?
    /// The server item the player opened on.
    let startedItemId: String?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")
    static let skipInterval: Double = 10

    init(
        request: PlaybackRequest,
        engine: AetherEngine,
        lease: EngineLease,
        resolver: PlaybackResolver,
        accounts: AccountStore,
        history: WatchHistory,
        settings: AppSettings,
        downloadedEpisode: @escaping (JellyfinItem) -> JellyfinItem?
    ) {
        self.request = request
        self.engine = engine
        self.lease = lease
        self.resolver = resolver
        self.accounts = accounts
        self.history = history
        self.settings = settings
        self.downloadedEpisode = downloadedEpisode
        title = request.title
        startedItemId = if case .item(let id, _) = request.source { id } else { nil }
    }

    var isTranscoding: Bool { current?.isTranscode ?? false }
    var isPlaying: Bool { status == .playing || status == .buffering }
    var item: JellyfinItem? { current?.item }
    /// The title on screen, or while it starts, as the screen it was picked on had it, for its
    /// picture.
    var shownItem: JellyfinItem? { current?.item ?? request.shownItem }

    /// Why the playback failed, while it has, and through a try again's first moment.
    var shownFailure: String? {
        switch status {
        case .failed(let message): message
        case .preparing, .loading: isRetrying ? failure : nil
        default: nil
        }
    }

    /// Why the playback failed last time it did.
    private(set) var failure = ""
    /// The scrub previews, from the server for a stream and from the saved files for a download.
    var trickplay: TrickplayTiles? { current?.trickplay }
    var chapters: [ChapterMark] { current?.chapters ?? [] }

    /// The playback whose session is open, which the server hears about; nil once it ended or failed.
    private var session: ResolvedPlayback? { sessionIsOpen ? current : nil }

    /// The intro, recap, preview or credits being played, which the player offers to skip.
    func skippableSegment(at time: Double) -> MediaSegment? {
        guard settings.showSkipButtons else { return nil }
        return segments.first { $0.skipTitle != nil && time >= $0.start && time < $0.end - 1 }
    }

    /// The end of the title on screen, by its length and the credits the server marks.
    var ending: TitleEnding { TitleEnding(duration: duration, segments: segments) }

    /// What the up-next card is about at `time`, while it belongs on screen: from the credits or
    /// the last half minute until the viewer hides it, and once the episode has ended, as the
    /// way on, whatever happened before.
    func upNextPhase(at time: Double) -> UpNextPhase? {
        guard nextEpisode != nil, let phase = ending.upNextPhase(at: time, hasEnded: status == .ended) else { return nil }
        return phase == .ended || !upNextDismissed ? phase : nil
    }

    func showsUpNext(at time: Double) -> Bool {
        upNextPhase(at: time) != nil
    }

    /// The title has ended with nothing after it: a movie, or a show's last episode. Its end
    /// screen offers it again, its page, and titles like it.
    var showsEndScreen: Bool {
        status == .ended && nextEpisode == nil && item != nil && !asksStillWatching
    }

    // MARK: Starting

    func start() async {
        await load(request)
    }

    /// Plays another episode, such as the next one, in place of this one, as the viewer asks.
    /// Asked again for the episode already starting, as a second press of Next is, it lets that
    /// one start.
    func play(_ episode: JellyfinItem) async {
        if requestedItemId == episode.id, status == .preparing || status == .loading { return }
        unattended.viewerActed()
        await switchTo(episode, inARow: episode.id == nextEpisode?.id)
    }

    /// `inARow`: it's the next episode, moved on to from this one.
    private func switchTo(_ episode: JellyfinItem, inARow: Bool) async {
        finishSession(status == .ended ? .reachedEnd : .left(toNextEpisode: episode.id == nextEpisode?.id))
        startsPaused = false
        startedInARow = inARow
        var next = PlaybackRequest.item(episode)
        if preparedNext?.id == episode.id { next.loadedItem = preparedNext }
        // Holds the last picture until the episode's first, where the engine can.
        engine.prepareForItemReplacement()
        await load(next)
    }

    /// Tries the title again after a failure: from where it had got to, with the audio and
    /// subtitles it had, when it got that far. The failure stays up for `retryHold` meanwhile.
    func retry() async {
        holdFailure()
        startsPaused = false
        await load(request.retrying(from: current != nil ? clock.time : nil), carrying: tracksToCarry())
    }

    /// Long enough for a try that fails at once to read as a try.
    private static let retryHold: Duration = .seconds(0.8)

    /// Keeps the failure up through a try again's first moment (`isRetrying`).
    private func holdFailure() {
        isRetrying = true
        retryHoldTask?.cancel()
        retryHoldTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryHold)
            guard !Task.isCancelled else { return }
            self?.isRetrying = false
        }
    }

    /// Rebuilds the picture after the system took the video pipeline away in the background.
    func restoreAfterBackground() async {
        guard session != nil, engine.needsForegroundVideoRestore else { return }
        do {
            try await engine.reloadAtCurrentPosition()
        } catch is CancellationError {
            return
        } catch {
            fail(error, engine: engine.errorInfo)
        }
    }

    /// Plays the same version again through the server's transcoder, for a file this device
    /// can't play directly: at the size the streaming limit allows, or 1080p without one, from
    /// where it got to and with the audio and subtitles it had.
    func retryTranscoded() async {
        guard let playing = current, let item = playing.item, let source = playing.mediaSource, !playing.isTranscode else { return }
        holdFailure()
        let position = clock.time > 0 ? clock.time : playing.startPosition
        let audioIndex: Int?
        let subtitleIndex: Int?
        if let tracks = tracksToCarry() {
            (audioIndex, subtitleIndex) = tracks.streamIndexes(in: source, settings: settings)
        } else {
            audioIndex = PlaybackResolver.preferredAudioIndex(in: source, language: settings.audioLanguage)
            subtitleIndex = PlaybackResolver.preferredSubtitleIndex(in: source, audioIndex: audioIndex, settings: settings)
        }
        let quality = settings.streamingLimit.transcodeQuality ?? .fullHD
        await startLoad { [self] generation in
            finishSession(.interrupted)
            startsPaused = false
            status = .loading
            do {
                let resolved = try await resolver.transcode(item: item, source: source, quality: quality,
                                                            audioIndex: audioIndex, subtitleIndex: subtitleIndex, start: position)
                guard loads.isCurrent(generation) else { return }
                await begin(resolved, generation: generation)
            } catch {
                guard loads.isCurrent(generation), !error.isCancellation else { return }
                fail(error)
            }
        }
    }

    /// Starts `request` in place of whatever plays or loads. `tracks` are the audio and subtitles
    /// a playback of the same title had, which this one keeps.
    private func load(_ request: PlaybackRequest, carrying tracks: TrackSelection? = nil) async {
        let isNewTitle = !request.playsSameTitle(as: self.request) || current == nil
        if isNewTitle {
            // Nothing of the title on screen carries over to another.
            if sessionIsOpen { finishSession(.left(toNextEpisode: false)) }
            current = nil
            isLoaded = false
            carriedTracks = nil
            playingTracks = nil
            title = request.title
            subtitle = nil
            reachedIntros = []
            similarTask?.cancel()
            similarTask = nil
            similarTitles = []
        }
        asksStillWatching = false
        dismissChip()
        // The engine plays what's ending until the new stream replaces it; none of it is this load's.
        subscriptions.removeAll()
        seekWait?.cancel()
        nextPreparation?.cancel()
        nextPreparation = nil
        preparedNext = nil
        self.request = request
        askedStreams = request.startingPoint
        status = startsPaused ? .paused : .preparing
        nextEpisode = nil
        lookedForNextEpisode = false
        segments = []
        upNextDismissed = false
        extrasRequestedFor = nil
        scrubbing.finish()
        let picks = sessionPicks
        await startLoad { [self] generation in
            do {
                let resolved = try await resolver.resolve(request, carrying: tracks, picks: picks)
                guard loads.isCurrent(generation) else { return }
                // A download's own copy, until the server's arrive.
                segments = resolved.segments
                await begin(resolved, carrying: tracks, generation: generation)
            } catch {
                guard loads.isCurrent(generation), !error.isCancellation else { return }
                fail(error)
            }
        }
    }

    /// Runs `work` as the one load under way (`LoadSequence`), in place of the one before and of
    /// any countdown to the next episode.
    private func startLoad(_ work: @escaping (_ generation: Int) async -> Void) async {
        countdownTask?.cancel()
        countdownTask = nil
        upNextCountdown = nil
        await loads.start(work)
    }

    /// Starts a stream of the title `load` resolved: the version it chose, or one standing in
    /// for it, which keeps the audio and subtitles `tracks` describe. Stops at the first wait
    /// after which `generation` is no longer the load under way.
    private func begin(_ resolved: ResolvedPlayback, carrying tracks: TrackSelection? = nil, generation: Int) async {
        guard !isClosed else { return }
        // The session this one replaces ends first, so the server hears it stopped.
        if sessionIsOpen { finishSession(.interrupted) }
        current = resolved
        sessionIsOpen = true
        title = resolved.title
        subtitle = resolved.subtitle
        duration = resolved.duration ?? 0
        videoFormat = .sdr
        videoSize = nil
        audioOptions = []
        subtitleOptions = []
        selectedAudio = nil
        selectedSubtitle = nil
        cues = []
        clock.time = resolved.startPosition ?? 0
        clock.sourceTime = resolved.startPosition ?? 0
        clock.buffered = 0
        carriedTracks = tracks
        playingTracks = nil
        // A version standing in for another keeps that one's tracks, whatever the request asked.
        if tracks != nil { askedStreams = nil }
        appliedSubtitlePreference = false
        isLoaded = false
        isPresenting = false
        startedReporting = false
        lastReportedPaused = nil
        watchTask?.cancel()
        status = startsPaused ? .paused : .loading
        updateSubtitleRendering()
        observeEngine()

        var options = LoadOptions()
        options.externalSubtitles = resolved.externalSubtitles
        options.matchContentEnabled = settings.matchContent
        let beganPaused = startsPaused
        options.autoplay = !beganPaused && (sharing?.startsByItself(resolved.item?.id) ?? true)
        #if os(iOS) || os(macOS)
        // The text subtitles also as the system's own, for Picture in Picture and AirPlay, where
        // the overlay isn't drawn (`pictureLeavesApp`).
        options.prepareNativeSubtitles = true
        #endif
        var audioStreamIndex: Int32?
        if let asked = askedStreams?.audioStreamIndex, !resolved.isTranscode {
            // An audio stream's index in the file is the server's.
            audioStreamIndex = Int32(asked)
        } else if let tracks, let audio = tracks.audio, !resolved.isTranscode {
            // By the server's list of the version's streams when it has one, else by language.
            let streams = resolved.mediaSource?.audioStreams.compactMap(TrackChooser.Candidate.init) ?? []
            audioStreamIndex = (tracks.exactAudioIndex(in: resolved.mediaSource) ?? TrackChooser.same(as: audio, in: streams)).map(Int32.init)
            options.preferredAudioLanguages = [audio.language, settings.audioLanguage].compactMap { $0 }.filter { !$0.isEmpty }
        } else if !resolved.isTranscode, let picked = resolved.trackPicks?.audio {
            // The audio the viewer picked in the show, by the server's list of the version's streams
            // when it has one, else by language.
            let streams = resolved.mediaSource?.audioStreams.compactMap(TrackChooser.Candidate.init) ?? []
            audioStreamIndex = resolved.trackPicks?.audio(in: streams).map(Int32.init)
            options.preferredAudioLanguages = [picked.language, settings.audioLanguage].compactMap { $0 }.filter { !$0.isEmpty }
        } else if !resolved.isTranscode, let described = describedAudio(in: resolved.mediaSource) {
            // Audio Descriptions asks for the description, which the engine ranks below the main mix.
            audioStreamIndex = Int32(described)
        } else if !settings.audioLanguage.isEmpty {
            options.preferredAudioLanguages = [settings.audioLanguage]
        }
        if resolved.isTranscode {
            options.nativeRemoteHLS = true
        }
        setNowPlaying(resolved)
        lease.holder = id
        do {
            try await engine.load(url: resolved.url, startPosition: resolved.startPosition, options: options,
                                  audioSourceStreamIndex: audioStreamIndex)
        } catch {
            guard loads.isCurrent(generation), !isClosed, !(error is CancellationError) else { return }
            fail(error, engine: engine.errorInfo)
            return
        }
        guard loads.isCurrent(generation), !isClosed else { return }
        isLoaded = true
        // A pause or a play while it loaded, which the load's own start would otherwise undo or miss.
        if startsPaused, engine.state != .paused {
            engine.pause()
        } else if beganPaused, !startsPaused {
            engine.play()
        }
        // The chapters marked in the file, for a playback the server gives none for.
        if current?.chapters.isEmpty == true, !engine.mediaChapters.isEmpty {
            current?.chapters = PlaybackResolver.chapters(from: engine.mediaChapters)
        }
        // A speed picked for one episode carries on to the next.
        if rate != 1 { engine.setRate(rate) }
        applyAudioDescriptionPreference()
        applySubtitlePreference(engine.subtitleTracks)
        notePlayingTracks()
        registerRemoteCommands()
        // A playback that waits to start, as one watched together can, is paused from the outset.
        Self.keepScreenAwake(!startsPaused && engine.state != .paused)
        startReporting()
        if resolved.isStream { watchConnection() }
        // Watched together, the group sets the position, and a start over would be everyone's.
        if resolved.resumesSavedPosition, sharing == nil, let start = resolved.startPosition {
            show(.resumed(at: start), for: Self.resumeChipSeconds)
        }
        let extras = ExtrasKey(title: resolved.historyKey, version: resolved.mediaSource?.versionItemId)
        if extrasRequestedFor != extras {
            let isNewTitle = extrasRequestedFor?.title != extras.title
            // Another version's skip markers don't fit this one's timeline.
            if !isNewTitle { segments = resolved.segments }
            extrasRequestedFor = extras
            Task { await loadExtras(for: resolved, includingNextEpisode: isNewTitle) }
        }
    }

    private struct ExtrasKey: Equatable {
        let title: String
        let version: String?
    }

    /// Whether `resolved` is still the version playing.
    private func isPlaying(_ resolved: ResolvedPlayback) -> Bool {
        current?.historyKey == resolved.historyKey && current?.mediaSource?.id == resolved.mediaSource?.id
    }

    /// What playback doesn't wait for: the skippable segments of the version playing, its
    /// chapters when it isn't the item's own version, and once for the title, the next episode.
    /// A download falls back on its saved segments and on the next episode downloaded. Why the
    /// server couldn't give one is logged, and for a stream, where the skip buttons, chapters or
    /// next episode would be missed, the player says which once for the title.
    private func loadExtras(for resolved: ResolvedPlayback, includingNextEpisode: Bool) async {
        guard let item = resolved.item else { return }
        let version = resolved.mediaSource?.versionItemId ?? item.id
        var missing: [String] = []
        var foundNext = false
        var nextFailed = false
        if let client = accounts.client, let account = accounts.account {
            do {
                let found = try await client.mediaSegments(itemId: version)
                if isPlaying(resolved) { segments = found }
            } catch JellyfinError.http(let status, _) where status == 404 {
                // The server keeps no segments for it.
            } catch is CancellationError {
                return
            } catch {
                Self.log.notice("Couldn't load the segments to skip: \(error.localizedDescription, privacy: .public)")
                if resolved.segments.isEmpty { missing.append("the skip buttons") }
            }
            if resolved.isStream, let source = resolved.mediaSource, version != item.id {
                do {
                    let detail = try await client.item(id: version, userId: account.userId)
                    let chapters = PlaybackResolver.chapters(of: detail, playing: source, client: client)
                    // Those marked in the file stand when the server has none.
                    if isPlaying(resolved), !chapters.isEmpty { current?.chapters = chapters }
                } catch JellyfinError.http(let status, _) where status == 404 {
                    // A version that isn't an item of its own has no chapters.
                } catch is CancellationError {
                    return
                } catch {
                    Self.log.notice("Couldn't load the version's chapters: \(error.localizedDescription, privacy: .public)")
                    missing.append("the chapters")
                }
            }
            if includingNextEpisode, item.isEpisode, let seriesId = item.seriesId {
                do {
                    let next = try await client.episode(after: item.id, seriesId: seriesId, userId: account.userId)
                    if current?.historyKey == resolved.historyKey { nextEpisode = next }
                    foundNext = true
                } catch is CancellationError {
                    return
                } catch {
                    Self.log.notice("Couldn't find the next episode: \(error.localizedDescription, privacy: .public)")
                    nextFailed = true
                }
            }
        }
        guard isPlaying(resolved), includingNextEpisode else { return }
        if item.isEpisode, !foundNext {
            nextEpisode = downloadedEpisode(item)
            if nextEpisode == nil, nextFailed { missing.append("the next episode") }
        }
        lookedForNextEpisode = true
        if resolved.isStream, !missing.isEmpty {
            show("Couldn't load \(missing.formatted(.list(type: .and))).", .info, for: 6)
        }
    }

    /// Ends the playback in a failure, told in a plain sentence (`PlaybackFailureMessage`) while
    /// what went wrong goes to the log. The server hears the session stop, and its transcode is
    /// stopped. `engine` is the engine's account of a failure of its own.
    private func fail(_ error: any Error, engine info: PlaybackErrorInfo? = nil) {
        Self.log.error("""
            Playback failed: \(String(describing: error), privacy: .public)\
            \(info.map { " (\($0.kind.rawValue), \($0.underlyingDomain ?? "-") \($0.underlyingCode ?? 0))" } ?? "", privacy: .public)
            """)
        status = .failed(PlaybackFailureMessage.text(for: error, engine: info))
        finishSession(.interrupted)
    }

    // MARK: Engine state

    /// Follows the engine from here on. Its publishers replay their current values on
    /// subscription, which belong to whatever played last (its ending, its duration), so the
    /// replay is dropped: taking it marked a next episode watched as it started.
    private func observeEngine() {
        subscriptions.removeAll()
        engine.$state.dropFirst().receive(on: RunLoop.main).sink { [weak self] state in self?.engineStateChanged(state) }
            .store(in: &subscriptions)
        engine.$playbackPhase.dropFirst().receive(on: RunLoop.main).sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &subscriptions)
        engine.$startupProgress.dropFirst().receive(on: RunLoop.main).sink { [weak self] progress in self?.startupChanged(progress) }
            .store(in: &subscriptions)
        engine.$duration.dropFirst().receive(on: RunLoop.main).sink { [weak self] duration in
            if duration > 0 { self?.duration = duration }
        }
        .store(in: &subscriptions)
        engine.$videoFormat.dropFirst().receive(on: RunLoop.main).sink { [weak self] format in self?.videoFormat = format }
            .store(in: &subscriptions)
        engine.$sourceVideoWidth.combineLatest(engine.$sourceVideoHeight).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] width, height in
                guard let self else { return }
                self.videoSize = width > 0 && height > 0
                    ? CGSize(width: Double(width) * self.engine.sourceVideoPixelAspectRatio, height: Double(height))
                    : nil
            }
            .store(in: &subscriptions)
        engine.$subtitleCues.dropFirst().receive(on: RunLoop.main).sink { [weak self] cues in
            guard let self else { return }
            self.cues = self.systemDrawsSubtitles ? [] : cues
        }
        .store(in: &subscriptions)
        engine.$audioTracks.combineLatest(engine.$activeAudioTrackIndex).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] tracks, active in self?.audioTracksChanged(tracks, active: active) }
            .store(in: &subscriptions)
        engine.$subtitleTracks.combineLatest(engine.$activeSubtitleTrackIndex).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] tracks, active in self?.subtitleTracksChanged(tracks, active: active) }
            .store(in: &subscriptions)
        // The engine sets its clock to zero as it loads, before seeking to the start position, and
        // can run it for seconds before the first frame is up, as when a start far from a keyframe
        // is decoded in software. Until the picture shows, the timeline keeps the start position
        // `begin` gave it.
        engine.clock.$currentTime.dropFirst().receive(on: RunLoop.main).sink { [weak self] time in
            guard let self, self.isLoaded, self.isPresenting else { return }
            self.clock.time = time
            self.prepareNextEpisodeIfDue(at: time)
            self.followEnding(at: time)
            self.skipIntroIfDue(at: time)
        }
        .store(in: &subscriptions)
        engine.clock.$sourceTime.dropFirst().receive(on: RunLoop.main).sink { [weak self] time in
            guard let self, self.isLoaded else { return }
            self.clock.sourceTime = time
        }
        .store(in: &subscriptions)
        engine.clock.$bufferedPosition.dropFirst().receive(on: RunLoop.main).sink { [weak self] position in self?.clock.buffered = position }
            .store(in: &subscriptions)
        #if os(iOS) || os(macOS)
        // AirPlay, or a screen plugged in, shows the picture where the overlay can't go.
        engine.$currentAVPlayer
            .map { player in
                player.map { $0.publisher(for: \.isExternalPlaybackActive).eraseToAnyPublisher() } ?? Just(false).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] external in self?.pictureLeavesApp(external, to: .externalPlayback) }
            .store(in: &subscriptions)
        #endif
    }

    private func engineStateChanged(_ state: PlaybackState) {
        defer { nowPlayingChanged() }
        switch state {
        case .ended:
            guard status != .ended else { return }
            status = .ended
            Self.keepScreenAwake(false)
            reachedEnd()
        case .error(let message):
            // Classified by the engine just before it published the failure.
            let info = engine.errorInfo
            Self.log.error("""
                The engine failed (\(info?.kind.rawValue ?? "unclassified", privacy: .public), \
                \(info?.underlyingDomain ?? "-", privacy: .public) \(info?.underlyingCode ?? 0)): \(message, privacy: .public)
                """)
            status = .failed(info.map { PlaybackFailureMessage.text(for: $0) } ?? PlaybackFailureMessage.unknown)
            finishSession(.interrupted)
        case .paused:
            if status != .ended { status = .paused }
            reportPauseChange(paused: true)
            // Paused, the screen dims and the screensaver comes on after the system's idle time.
            Self.keepScreenAwake(false)
        case .playing:
            // A start the engine has taken back since, as `begin` does a load's paused while it ran.
            guard engine.state != .paused else { return }
            startsPaused = false
            status = isPresenting ? .playing : .loading
            reportPauseChange(paused: false)
            Self.keepScreenAwake(true)
        case .loading, .seeking, .idle:
            break
        }
    }

    private func phaseChanged(_ phase: PlaybackPhase) {
        // A seek's wait is a start of its own, whoever asked for it: the system's remote commands
        // seek the engine directly.
        if phase == .seeking { connectionWatch.restart() }
        if phase != .seeking {
            seekWait?.cancel()
            seekWait = nil
        }
        switch phase {
        case .seeking:
            // A seek that lands at once shows as the moving playhead; one that hasn't after a
            // moment as waiting, so a run of skips doesn't flash the spinner.
            guard status == .playing, seekWait == nil else { return }
            seekWait = Task { [weak self] in
                try? await Task.sleep(for: Self.seekPatience)
                guard let self, !Task.isCancelled, self.engine.playbackPhase == .seeking, self.status == .playing else { return }
                self.status = .buffering
            }
        case .rebuffering, .stalled:
            if status == .playing { status = .buffering }
        case .playing:
            if isPresenting, status == .buffering || status == .loading { status = .playing }
        default:
            break
        }
    }

    /// How long a seek can take before the player shows it's waiting for it.
    private static let seekPatience = Duration.milliseconds(400)

    /// A picture that comes up after the engine started playing turns loading into playing.
    private func startupChanged(_ progress: StartupProgress?) {
        isPresenting = progress?.isComplete == true
        guard isPresenting, status == .loading, engine.state == .playing else { return }
        status = .playing
        phaseChanged(engine.playbackPhase)
        nowPlayingChanged()
    }

    private func audioTracksChanged(_ tracks: [TrackInfo], active: Int?) {
        if let transcode = current?.transcode, let source = current?.mediaSource {
            audioOptions = source.audioStreams.compactMap { stream in
                stream.index.map { TrackOption(id: $0, title: Self.streamTitle(stream), detail: stream.displayTitle) }
            }
            selectedAudio = transcode.audioIndex ?? source.defaultAudioStreamIndex ?? audioOptions.first?.id
            return
        }
        audioOptions = tracks.map { TrackOption(id: $0.id, title: Self.trackTitle($0), detail: Self.audioDetail($0)) }
        let previous = selectedAudio
        selectedAudio = active
        if isLoaded, previous != active { reportProgressNow() }
        notePlayingTracks()
    }

    private func subtitleTracksChanged(_ tracks: [TrackInfo], active: Int?) {
        if let transcode = current?.transcode, let source = current?.mediaSource {
            subtitleOptions = source.subtitleStreams.compactMap { stream in
                stream.index.map { TrackOption(id: $0, title: Self.streamTitle(stream), detail: stream.codec?.uppercased()) }
            }
            selectedSubtitle = transcode.subtitleIndex
            // The server lists its text subtitles as HLS renditions; turn on the one asked for, and
            // with none asked for, off any a rendition's DEFAULT turned on.
            if let index = transcode.subtitleIndex,
               let asked = source.subtitleStreams.first(where: { $0.index == index }).flatMap(TrackChooser.Candidate.init),
               let rendition = TrackChooser.same(as: asked, in: tracks.map(TrackChooser.Candidate.init)), active != rendition {
                engine.selectSubtitleTrack(index: rendition)
            } else if transcode.subtitleIndex == nil, active != nil {
                engine.clearSubtitle()
            }
            return
        }
        subtitleOptions = tracks.map { TrackOption(id: $0.id, title: Self.trackTitle($0), detail: Self.subtitleDetail($0)) }
        let previous = selectedSubtitle
        selectedSubtitle = active
        if isLoaded {
            applySubtitlePreference(tracks)
            if previous != active { reportProgressNow() }
        }
        notePlayingTracks()
    }

    /// Keeps the audio and subtitles of a version playing as they change, for another stream of
    /// the title to keep (`tracksToCarry`) after this one ended or failed, by when the engine may
    /// have let go of them. One it has let go of, with no track on, changes nothing.
    private func notePlayingTracks() {
        guard isLoaded, !isTranscoding, engine.activeAudioTrackIndex != nil || engine.activeSubtitleTrackIndex != nil else { return }
        playingTracks = currentTrackSelection()
    }

    /// Turns on the subtitle track the subtitle setting asks for, once per playback, after the
    /// load has listed the tracks. A version standing in for another keeps that one's choice,
    /// subtitles off included, when it has the same, and the viewer's picks in the show
    /// (`TrackPicks`) come before the setting.
    private func applySubtitlePreference(_ tracks: [TrackInfo]) {
        guard !appliedSubtitlePreference, !isTranscoding, !tracks.isEmpty else { return }
        appliedSubtitlePreference = true
        let candidates = tracks.map(TrackChooser.Candidate.init)
        let choice: Int?
        if let asked = askedStreams?.subtitleStreamIndex {
            choice = asked < 0 ? nil : streamMap.trackId(forStream: asked) ?? preferredSubtitle(from: candidates)
            askedStreams = nil
        } else if let carried = carriedTracks, let subtitle = carried.subtitle {
            choice = carried.exactSubtitleIndex(in: current?.mediaSource).flatMap(streamMap.trackId(forStream:))
                ?? TrackChooser.same(as: subtitle, in: candidates) ?? preferredSubtitle(from: candidates)
        } else if carriedTracks != nil {
            choice = nil
        } else if let picked = current?.trackPicks?.subtitles(in: candidates) {
            choice = picked.trackId
        } else {
            choice = preferredSubtitle(from: candidates)
        }
        if let choice {
            engine.selectSubtitleTrack(index: choice)
        } else if engine.activeSubtitleTrackIndex != nil {
            engine.clearSubtitle()
        }
    }

    private func preferredSubtitle(from candidates: [TrackChooser.Candidate]) -> Int? {
        let audioLanguage = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.language
        return TrackChooser.subtitle(from: candidates, audioLanguage: audioLanguage,
                                     mode: settings.subtitleMode, language: settings.subtitleLanguage,
                                     captions: AccessibleMedia.prefersCaptions)
    }

    /// The audio description that Audio Descriptions asks for, from the server's list of the
    /// version's streams, whose indexes are the file's; nil when it's off or there's none.
    private func describedAudio(in source: MediaSource?) -> Int? {
        guard AccessibleMedia.prefersAudioDescriptions, let source else { return nil }
        let candidates = source.audioStreams.compactMap(TrackChooser.Candidate.init)
        guard let pick = TrackChooser.audio(from: candidates, language: settings.audioLanguage,
                                            defaultId: source.defaultAudioStreamIndex, descriptions: true),
              candidates.first(where: { $0.id == pick })?.describesVideo == true else { return nil }
        return pick
    }

    /// For a file the server doesn't list the streams of, a file on this device: turns on the
    /// audio description Audio Descriptions asks for, once the load has listed the tracks.
    private func applyAudioDescriptionPreference() {
        guard current?.mediaSource == nil, askedStreams?.audioStreamIndex == nil, carriedTracks == nil,
              current?.trackPicks?.audio == nil, AccessibleMedia.prefersAudioDescriptions else { return }
        let candidates = engine.audioTracks.map(TrackChooser.Candidate.init)
        guard let active = candidates.first(where: { $0.id == engine.activeAudioTrackIndex }), !active.describesVideo,
              let pick = TrackChooser.audio(from: candidates, language: settings.audioLanguage, defaultId: active.id, descriptions: true),
              candidates.first(where: { $0.id == pick })?.describesVideo == true else { return }
        engine.selectAudioTrack(index: pick)
    }

    // MARK: Commands

    // The viewer's commands, from the controls, the system's remote commands and other devices.
    // Watched together, the transport goes to the group, which applies it everywhere through the
    // group commands below.

    func togglePlayPause() {
        // Someone is watching: a question about it goes, and playing on answers it.
        unattended.viewerActed()
        asksStillWatching = false
        switch status {
        case .ended:
            // The way on is the next episode, as the up-next card offers, when there is one.
            if let nextEpisode {
                Task { await play(nextEpisode) }
            } else {
                watchAgain()
            }
        case .failed:
            return
        case .preparing, .loading:
            // A playback on its way to playing: the press pauses what's coming.
            pause()
        case .paused where startsPaused:
            play()
        default:
            if sharing?.share(.rate(isPlaying ? 0 : rate)) == true { return }
            engine.togglePlayPause()
        }
    }

    func play() {
        guard status != .ended else { return }
        if sharing?.share(.rate(rate)) == true { return }
        playHere()
    }

    func pause() {
        if sharing?.share(.rate(0)) == true { return }
        pauseHere()
    }

    /// Pauses, or while the playback starts, has it start paused (`startsPaused`).
    private func pauseHere() {
        guard status == .preparing || status == .loading else {
            engine.pause()
            return
        }
        startsPaused = true
        status = .paused
        // The stream starting, or the one it replaces; a load under way starts its stream as it
        // returns, which `begin` pauses.
        engine.pause()
    }

    /// Plays, or lets a playback paused while it started start playing.
    private func playHere() {
        if startsPaused {
            startsPaused = false
            guard sessionIsOpen, isLoaded else {
                // The engine has another stream, or none, until the load under way returns and
                // `begin` plays this one.
                status = sessionIsOpen ? .loading : .preparing
                return
            }
        }
        engine.play()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        clock.time = target
        if sharing?.share(.seek(target)) == true { return }
        guard status != .ended else {
            Task { await replay(from: target) }
            return
        }
        connectionWatch.restart()
        nowPlayingChanged()
        // The end of an intro or of the credits, exactly: the software AV1 path otherwise lands
        // on a keyframe up to ten seconds before it.
        let exact = segments.contains { abs($0.end - seconds) < 0.001 }
        Task {
            await engine.seek(to: target, exact: exact)
            reportProgressNow()
        }
    }

    func skip(by seconds: Double) {
        // After the end there's nothing ahead to skip to.
        if status == .ended, seconds > 0 { return }
        scrubbing.noteSkip(seconds)
        seek(to: clock.time + seconds)
    }

    /// Plays the title that ended again from `position`, with the audio and subtitles it had: the
    /// engine's ended session can be neither moved nor resumed (`.ended` is terminal), so the
    /// title loads again. Nothing plays from the very end.
    private func replay(from position: Double) async {
        guard duration <= 0 || position < duration - 1 else { return }
        let tracks = tracksToCarry()
        clock.time = position
        startsPaused = false
        await load(request.replaying(from: position, title: title), carrying: tracks)
    }

    // The timeline moved without seeking yet, as the Apple TV remote scrubs: a position is chosen,
    // then committed, which seeks there, or dropped.

    /// Moves the position being chosen by `seconds`, starting from the playhead.
    func scrub(by seconds: Double) {
        scrubbing.move(by: seconds, from: clock.time, duration: duration)
    }

    /// Scans forward or back from the position being chosen, or the playhead, until committed.
    func beginScan(forward: Bool) {
        scrubbing.beginScan(forward: forward, from: clock.time, duration: duration)
    }

    /// Seeks to the position chosen, if there is one.
    func commitScrub() {
        guard let target = scrubbing.finish() else { return }
        seek(to: target)
    }

    /// Drops the position chosen, leaving playback where it is.
    func cancelScrub() {
        scrubbing.finish()
    }

    /// Paused, the speed waits for the next play, here and in a group.
    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying, sharing?.share(.rate(newRate)) == true { return }
        engine.setRate(newRate)
        nowPlayingChanged()
    }

    // A transcode's choices are the menus' until its new stream starts, so a second choice made
    // meanwhile keeps the first.

    func chooseAudio(_ id: Int) {
        if let picked = audioCandidate(id) { pick { $0.audio = TrackPicks.Track(picked) } }
        if isTranscoding {
            selectedAudio = id
            Task { await reloadTranscode(audioIndex: id, subtitleIndex: selectedSubtitle) }
        } else {
            engine.selectAudioTrack(index: id)
        }
    }

    /// Nil turns subtitles off.
    func chooseSubtitle(_ id: Int?) {
        if let id {
            if let picked = subtitleCandidate(id) { pick { $0.subtitles = .track(TrackPicks.Track(picked)) } }
        } else {
            pick { $0.subtitles = .off }
        }
        if isTranscoding {
            selectedSubtitle = id
            Task { await reloadTranscode(audioIndex: selectedAudio, subtitleIndex: id) }
        } else if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
    }

    // MARK: Picks for the show

    /// Keeps a pick of the viewer's for the show playing: its other episodes start with it, this
    /// session and next time (`TrackPicks`).
    private func pick(_ change: (inout TrackPicks) -> Void) {
        unattended.viewerActed()
        guard let seriesId = item?.seriesId else { return }
        var picks = sessionPicks?.seriesId == seriesId ? sessionPicks?.picks ?? TrackPicks() : TrackPicks()
        change(&picks)
        sessionPicks = ShowPicks(seriesId: seriesId, picks: picks)
        settings.trackMemory.remember(picks, forShow: seriesId)
    }

    /// The audio the menus number `id`: a transcode's by the server's index, else the engine's track.
    private func audioCandidate(_ id: Int) -> TrackChooser.Candidate? {
        if isTranscoding {
            return current?.mediaSource?.audioStreams.first { $0.index == id }.flatMap(TrackChooser.Candidate.init)
        }
        return engine.audioTracks.first { $0.id == id }.map(TrackChooser.Candidate.init)
    }

    private func subtitleCandidate(_ id: Int) -> TrackChooser.Candidate? {
        if isTranscoding {
            return current?.mediaSource?.subtitleStreams.first { $0.index == id }.flatMap(TrackChooser.Candidate.init)
        }
        return engine.subtitleTracks.first { $0.id == id }.map(TrackChooser.Candidate.init)
    }

    // MARK: The end of an episode

    /// Hide, Watch Credits, or Back on Apple TV: the countdown stops and the next episode waits to
    /// be picked. Before the end the card goes too; once the episode ends it's back as the way on.
    func cancelUpNext() {
        unattended.viewerActed()
        stopCountdown()
        upNextDismissed = true
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        upNextCountdown = nil
    }

    /// Plays the title that ended again from the beginning, as the end screen's and the up-next
    /// card's Watch Again do. A group starts over together.
    func watchAgain() {
        unattended.viewerActed()
        if sharing?.share(.seek(0)) == true { return }
        Task { await replay(from: 0) }
    }

    /// Someone answered "Still watching?": the next episode plays.
    func continueWatching() async {
        unattended.viewerActed()
        asksStillWatching = false
        guard let nextEpisode else { return }
        await play(nextEpisode)
    }

    /// The viewer brought up the controls or otherwise used the player, so someone is watching
    /// (`UnattendedAutoplay`).
    func noteViewerActivity() {
        unattended.viewerActed()
    }

    /// Plays the title from its beginning, from the chip that says it resumed.
    func startOver() {
        dismissChip()
        unattended.viewerActed()
        seek(to: 0)
    }

    /// Goes back to the intro Skip Intros skipped, which then plays.
    func watchIntro() {
        guard case .skippedIntro(let intro) = chip else { return }
        dismissChip()
        unattended.viewerActed()
        seek(to: intro.start)
    }

    func playNextEpisode() async {
        guard let nextEpisode else { return }
        await play(nextEpisode)
    }

    /// The episode before this one; the start of this one when there's none before it.
    func playPreviousEpisode() async {
        guard let item, item.isEpisode, let seriesId = item.seriesId, let client = accounts.client,
              let account = accounts.account else {
            seek(to: 0)
            return
        }
        do {
            if let previous = try await client.episode(before: item.id, seriesId: seriesId, userId: account.userId) {
                await play(previous)
            } else {
                seek(to: 0)
            }
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("Couldn't find the episode before \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            show("Couldn't find the previous episode.", .info, for: 6)
        }
    }

    // MARK: Picture outside the app

    /// Where the picture can be shown outside the app's own view.
    enum PictureOutside: Hashable {
        case pictureInPicture
        /// AirPlay, or a screen plugged in.
        case externalPlayback
    }

    /// The picture went to, or came back from, `place` outside the app's view, where the subtitle
    /// overlay isn't drawn. Meanwhile the system draws the subtitles, from the engine's own
    /// renditions of them, and the overlay draws none.
    func pictureLeavesApp(_ leaves: Bool, to place: PictureOutside = .pictureInPicture) {
        if leaves { pictureOutside.insert(place) } else { pictureOutside.remove(place) }
        updateSubtitleRendering()
    }

    /// The picture is in Picture in Picture.
    var isInPictureInPicture: Bool { pictureOutside.contains(.pictureInPicture) }

    /// Hands the subtitles to the system while the picture is outside the app, and takes them
    /// back. Not a transcode's: AVPlayer draws those itself wherever the picture is, and handing
    /// them over, with no renditions of the engine's own to show, would turn them off.
    private func updateSubtitleRendering() {
        let systemDraws = !pictureOutside.isEmpty && current?.isTranscode == false
        guard systemDraws != systemDrawsSubtitles else { return }
        systemDrawsSubtitles = systemDraws
        engine.setNativeSubtitleRendering(systemDraws)
        cues = systemDraws ? [] : engine.subtitleCues
    }

    // MARK: Streams by the server's numbers

    /// The server's index of the audio stream playing; nil for a file of this device's.
    var audioStreamIndex: Int? {
        guard let current, current.reporting != nil, let selectedAudio else { return nil }
        return current.isTranscode ? selectedAudio : streamMap.streamIndex(forTrack: selectedAudio)
    }

    /// The server's index of the subtitle stream showing, -1 with subtitles off; nil for a file of
    /// this device's.
    var subtitleStreamIndex: Int? {
        guard let current, current.reporting != nil else { return nil }
        guard let selectedSubtitle else { return -1 }
        return current.isTranscode ? selectedSubtitle : streamMap.streamIndex(forTrack: selectedSubtitle)
    }

    /// Plays the audio stream the server numbers `index`, as another device asks.
    func chooseAudio(streamIndex index: Int) {
        if isTranscoding {
            chooseAudio(index)
        } else if let track = streamMap.trackId(forStream: index) {
            chooseAudio(track)
        } else {
            Self.log.notice("Another device asked for audio stream \(index), which this version hasn't got")
            show("The audio asked for isn't in this version.", .remoteRequest, for: 4)
        }
    }

    /// Shows the subtitle stream the server numbers `index`, or none, as another device asks.
    func chooseSubtitle(streamIndex index: Int?) {
        guard let index else {
            chooseSubtitle(nil)
            return
        }
        if isTranscoding {
            chooseSubtitle(index)
        } else if let track = streamMap.trackId(forStream: index) {
            chooseSubtitle(track)
        } else {
            Self.log.notice("Another device asked for subtitle stream \(index), which didn't load here")
            show("The subtitles asked for aren't in this version.", .remoteRequest, for: 4)
        }
    }

    private var streamMap: StreamIndexMap {
        StreamIndexMap(streams: current?.mediaSource?.mediaStreams ?? [], tracks: engine.audioTracks + engine.subtitleTracks)
    }

    // MARK: Group commands

    /// The server item asked for, while it loads and once it plays.
    var requestedItemId: String? {
        if case .item(let id, _) = request.source { id } else { nil }
    }

    /// Where another device the playback moves to starts: where it got to, or the beginning
    /// once it has ended.
    var handOverPosition: Double {
        status == .ended ? 0 : clock.time
    }

    /// Plays at `rate`, or pauses at 0, as the group watching together asks.
    func applyRate(_ newRate: Float) {
        guard newRate != 0 else {
            pauseHere()
            return
        }
        if rate != newRate {
            rate = newRate
            engine.setRate(newRate)
        }
        playHere()
        nowPlayingChanged()
    }

    /// Moves to `seconds` exactly, as the group asks. A stream that ended plays again from there.
    func applySeek(to seconds: Double) async {
        if status == .ended {
            await replay(from: seconds)
            return
        }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        clock.time = target
        connectionWatch.restart()
        nowPlayingChanged()
        await engine.seek(to: target, exact: true)
        reportProgressNow()
    }

    /// A transcode carries its audio and subtitles in the stream, so changing them asks the
    /// server for a new one at the same spot and quality. The stream playing goes on until the new
    /// one starts, holding its picture there; when the server can't give one, it goes on as it is.
    private func reloadTranscode(audioIndex: Int?, subtitleIndex: Int?) async {
        guard let playing = session, let item = playing.item, let source = playing.mediaSource,
              let transcode = playing.transcode else { return }
        await startLoad { [self] generation in
            var resolved: ResolvedPlayback
            do {
                resolved = try await resolver.transcode(item: item, source: source, quality: transcode.quality,
                                                        audioIndex: audioIndex, subtitleIndex: subtitleIndex, start: clock.time)
            } catch {
                guard loads.isCurrent(generation), !error.isCancellation else { return }
                Self.log.error("Couldn't change the transcode's tracks: \(String(describing: error), privacy: .public)")
                selectedAudio = transcode.audioIndex ?? source.defaultAudioStreamIndex ?? audioOptions.first?.id
                selectedSubtitle = transcode.subtitleIndex
                show("Couldn't change the audio or subtitles.", .connection, for: 6)
                return
            }
            guard loads.isCurrent(generation), !isClosed, session?.reporting?.playSessionId == playing.reporting?.playSessionId else { return }
            // Where the stream playing got to while the new one was being asked for, and paused
            // if it was.
            resolved.startPosition = engine.clock.currentTime
            if engine.state == .paused { startsPaused = true }
            engine.prepareForItemReplacement()
            await begin(resolved, generation: generation)
        }
    }

    // MARK: Adaptive quality

    /// Samples the playback once a second for `ConnectionWatch`, and moves to a cheaper stream of
    /// the title when it says the connection can't keep up. The watch starts over with each
    /// stream, and nothing moves back up: the next playback starts at the streaming limit again,
    /// which is lower once enough of these teach this device a bitrate to stay under.
    private func watchConnection() {
        connectionWatch = ConnectionWatch(isTranscode: current?.isTranscode ?? false)
        ExpensiveNetwork.follow()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.settings.adaptiveQuality else {
                    self.connectionWatch.restart()
                    continue
                }
                let sample = self.connectionSample()
                if let reason = self.connectionWatch.observe(sample) {
                    self.learn(from: reason, sample: sample)
                    // In a task of its own: starting the new stream cancels this one.
                    Task { await self.stepDown(because: reason) }
                    return
                }
            }
        }
    }

    /// Counts a stream the connection couldn't carry toward the bitrate this device learns to
    /// stay under, when the connection is what couldn't carry it.
    private func learn(from reason: ConnectionWatch.Reason, sample: ConnectionWatch.Sample) {
        guard let playing = current, let item = playing.item, let plan = playing.plan,
              let incident = QualityLearning.Incident(reason, playing: plan, of: item, sample: sample,
                                                      throughput: connectionWatch.throughput,
                                                      isExpensiveNetwork: ExpensiveNetwork.isActive)
        else { return }
        guard let limit = settings.learnedQuality.record(incident) else { return }
        Self.log.notice("""
            Streams kept rebuffering on separate days, the last at \(incident.bitrate) b/s and \
            \(incident.resolution ?? 0) lines: this device now stays under \(limit) b/s
            """)
    }

    private func connectionSample() -> ConnectionWatch.Sample {
        let telemetry = engine.diagnostics.liveTelemetry
        // A stream still starting is wanted, though `status` can read loading or paused until it
        // rolls. A source that's gone, and reconnecting, isn't slow: a cheaper version wouldn't get
        // through either.
        let isWanted = switch engine.playbackPhase {
        case .playing, .loading: true
        case .rebuffering: engine.state != .paused
        default: false
        }
        let declaredBitrate = current?.transcode.map(\.quality.transcodeBitrate)
            ?? current?.mediaSource.flatMap { VersionTraits($0).bitrate }
        return ConnectionWatch.Sample(
            time: ProcessInfo.processInfo.systemUptime,
            isWanted: isWanted,
            position: engine.clock.currentTime,
            rate: Double(rate),
            bufferedAhead: max(0, engine.clock.bufferedPosition - engine.clock.currentTime),
            throughput: telemetry?.networkThroughputMbps.map { $0 * 1_000_000 },
            bitrate: telemetry?.averageBitrateMbps.map { $0 * 1_000_000 } ?? declaredBitrate.map(Double.init)
        )
    }

    /// Moves to a cheaper version of the title, or to a transcode, from the same spot and with
    /// the same audio and subtitles.
    private func stepDown(because reason: ConnectionWatch.Reason) async {
        guard let playing = session, let item = playing.item, let plan = playing.plan else { return }
        let bitrate = engine.diagnostics.liveTelemetry?.averageBitrateMbps.map { Int($0 * 1_000_000) }
        let throughput = connectionWatch.throughput.map { Int($0) }
        guard let target = VersionChooser.planStepDown(from: plan, bitrate: bitrate, throughput: throughput,
                                                       sources: item.mediaSources ?? [], allowTranscoding: settings.allowTranscoding)
        else {
            Self.log.notice("The connection can't keep up (\(String(describing: reason), privacy: .public)), and nothing is cheaper")
            return
        }
        let quality = target.label ?? "a lower quality"
        let kind = if case .transcode = target { "a transcode" } else { "the version" }
        Self.log.notice("""
            The connection can't keep up (\(String(describing: reason), privacy: .public), \(throughput ?? 0) b/s for \
            \(bitrate ?? 0) b/s): moving to \(kind, privacy: .public) at \(quality, privacy: .public)
            """)
        let tracks = currentTrackSelection()
        await startLoad { [self] generation in
            var resolved: ResolvedPlayback
            do {
                switch target {
                case .direct(let source):
                    resolved = try resolver.direct(item: item, source: source, start: nil)
                case .transcode(let source, let quality):
                    let streams = tracks.streamIndexes(in: source, settings: settings)
                    resolved = try await resolver.transcode(item: item, source: source, quality: quality, audioIndex: streams.audio,
                                                            subtitleIndex: streams.subtitle, start: engine.clock.currentTime)
                }
            } catch {
                guard loads.isCurrent(generation), !error.isCancellation else { return }
                // The stream playing goes on as it is, and stays for this playback.
                Self.log.error("Couldn't switch: \(String(describing: error), privacy: .public)")
                show("Couldn't switch to \(quality).", .connection, for: 8)
                return
            }
            guard loads.isCurrent(generation), !isClosed, session?.reporting?.playSessionId == playing.reporting?.playSessionId else { return }
            // Where the old stream got to while the new one was being asked for, and paused if it was.
            resolved.startPosition = engine.clock.currentTime
            if engine.state == .paused { startsPaused = true }
            // Holds the picture until the new stream's first frame, where the engine can.
            engine.prepareForItemReplacement()
            finishSession(.interrupted)
            await begin(resolved, carrying: tracks, generation: generation)
            if loads.isCurrent(generation), isLoaded { show("Switched to \(quality) to keep playing", .connection, for: 4) }
        }
    }

    /// The audio and subtitles playing, described so another version can find its own: the
    /// menus' choices for a transcode, whose stream may not have caught up with them yet.
    private func currentTrackSelection() -> TrackSelection {
        let streams = current?.mediaSource.map { source in
            TrackSelection.ServerStreams(mediaSourceId: source.id, audio: audioStreamIndex,
                                         subtitle: subtitleStreamIndex.flatMap { $0 < 0 ? nil : $0 })
        }
        if let source = current?.mediaSource, isTranscoding {
            let audioIndex = selectedAudio ?? source.defaultAudioStreamIndex
            return TrackSelection(
                audio: (source.audioStreams.first { $0.index == audioIndex } ?? source.audioStreams.first).flatMap(TrackChooser.Candidate.init),
                subtitle: selectedSubtitle.flatMap { index in source.subtitleStreams.first { $0.index == index } }
                    .flatMap(TrackChooser.Candidate.init),
                streams: streams
            )
        }
        return TrackSelection(
            audio: engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }.map(TrackChooser.Candidate.init),
            subtitle: engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }.map(TrackChooser.Candidate.init),
            streams: streams
        )
    }

    /// The audio and subtitles another stream of the title on screen keeps: those playing once
    /// it loaded (a transcode's as the menus have them), else those it was itself carrying. Nil
    /// before any were chosen, which leaves them to the request and the language settings.
    private func tracksToCarry() -> TrackSelection? {
        guard current != nil else { return nil }
        guard isLoaded else { return carriedTracks }
        return isTranscoding ? currentTrackSelection() : playingTracks ?? currentTrackSelection()
    }

    /// Shows `text` over the picture for `seconds` of playback, so a stream slow to start keeps
    /// saying why the picture went.
    private func show(_ text: String, _ kind: PlaybackNotice.Kind, for seconds: Double) {
        notice = PlaybackNotice(text: text, kind: kind)
        noticeTask?.cancel()
        noticeTask = Task {
            for await status in Observations({ self.status }) where ![.preparing, .loading, .buffering, .paused].contains(status) {
                break
            }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: Ending

    /// Gives the title its end and, with autoplay, counts down to the next episode, unless the
    /// countdown from the credits runs on. With nothing after it, gets titles like it for the end
    /// screen.
    private func reachedEnd() {
        finishSession(.reachedEnd)
        prepareNextEpisodeIfDue(at: clock.time)
        if nextEpisode == nil {
            loadSimilarTitles()
        } else {
            beginUpNext(inCredits: false)
        }
    }

    /// Follows the playhead through the end of the episode: the countdown starts as the credits
    /// the server marks start, and one started there stops as the playhead moves back out of them
    /// (`TitleEnding`).
    private func followEnding(at time: Double) {
        guard status != .ended else { return }
        if upNextPhase(at: time) == .credits {
            beginUpNext(inCredits: true)
        } else if upNextCountdown?.startedInCredits == true {
            stopCountdown()
        }
        let nearsEnd = ending.isInCredits(at: time) || duration > 0 && duration - time <= Self.similarTitlesLead
        if nearsEnd, nextEpisode == nil, lookedForNextEpisode { loadSimilarTitles() }
    }

    /// How long before the end the end screen's titles are fetched.
    private static let similarTitlesLead: Double = 120

    /// With autoplay, counts down to the next episode (`UpNextCountdown`), from the credits or the
    /// end. After `UnattendedAutoplay.limit` episodes started by themselves with nobody doing
    /// anything, it pauses and asks whether anyone is still watching instead. Not while the
    /// viewer has said no to the next one, or while a countdown or the question is up already.
    private func beginUpNext(inCredits: Bool) {
        guard let next = nextEpisode, settings.autoplayNextEpisode, !upNextDismissed, upNextCountdown == nil,
              !asksStillWatching else { return }
        // Watched together, someone is: the group goes on as one.
        if unattended.asksFirst, sharing == nil {
            asksStillWatching = true
            if status != .ended { pauseHere() }
            return
        }
        upNextCountdown = UpNextCountdown(generation: loads.generation, episodeId: current?.item?.id, nextEpisodeId: next.id,
                                          startedInCredits: inCredits)
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, var countdown = self.upNextCountdown else { return }
                // Paused, or waiting for the stream, it waits too.
                guard self.status == .playing || self.status == .ended else { continue }
                countdown.remaining -= 1
                self.upNextCountdown = countdown
                guard countdown.remaining <= 0 else { continue }
                self.upNextCountdown = nil
                let isEnding = self.status == .ended || self.ending.isInCredits(at: self.clock.time)
                guard let next = self.nextEpisode,
                      countdown.isDue(loads: self.loads, onScreen: self.current?.item?.id, next: next.id, isEnding: isEnding)
                else { return }
                // Out of reach before the switch: its load cancels any countdown (`startLoad`), and
                // cancelling this one would cancel the load started from it.
                self.countdownTask = nil
                self.unattended.episodeStartedByItself()
                await self.switchTo(next, inARow: true)
                return
            }
        }
    }

    /// Fetches titles like the one playing, for its end screen, once it nears its end with
    /// nothing after it.
    private func loadSimilarTitles() {
        guard similarTask == nil, let item, let client = accounts.client, let account = accounts.account else { return }
        let titleId = item.titleId
        similarTask = Task { [weak self] in
            do {
                let found = try await client.similar(to: titleId, userId: account.userId, limit: Self.similarCount)
                guard let self, !Task.isCancelled, self.item?.titleId == titleId else { return }
                self.similarTitles = found
            } catch {
                guard !error.isCancellation else { return }
                Self.log.notice("Couldn't load titles like this one: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let similarCount = 8

    /// Skips the intro the playhead has just reached, once, when Skip Intros says to. Watched
    /// together, the button leaves it to whoever presses it, for everyone.
    private func skipIntroIfDue(at time: Double) {
        guard status == .playing, !scrubbing.isActive,
              let intro = segments.first(where: { $0.type == "Intro" && time >= $0.start && time < $0.end - 1 }),
              !reachedIntros.contains(intro.start) else { return }
        reachedIntros.insert(intro.start)
        guard sharing == nil, settings.introSkipping.skips(inARow: startedInARow) else { return }
        seek(to: intro.end)
        show(.skippedIntro(intro), for: Self.introChipSeconds)
    }

    private static let resumeChipSeconds: Double = 6
    private static let introChipSeconds: Double = 5

    /// Shows `chip` for `seconds` of playback, counted from when it plays, so a slow start doesn't
    /// use them up.
    private func show(_ chip: PlaybackChip, for seconds: Double) {
        self.chip = chip
        chipTask?.cancel()
        chipTask = Task {
            for await status in Observations({ self.status }) where status == .playing {
                break
            }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self.chip == chip else { return }
            self.chip = nil
        }
    }

    private func dismissChip() {
        chipTask?.cancel()
        chipTask = nil
        chip = nil
    }

    /// Fetches the next episode with its versions, and warms its stream, once the up-next card
    /// is due, so it starts sooner when it's played.
    private func prepareNextEpisodeIfDue(at time: Double) {
        guard nextPreparation == nil, let next = nextEpisode, ending.upNextPhase(at: time, hasEnded: status == .ended) != nil,
              let client = accounts.client, let account = accounts.account else { return }
        nextPreparation = Task { [weak self] in
            let item: JellyfinItem
            do {
                item = try await client.item(id: next.id, userId: account.userId)
            } catch {
                if !error.isCancellation {
                    Self.log.notice("Couldn't load the next episode ahead: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard let self, !Task.isCancelled, self.nextEpisode?.id == item.id else { return }
            self.preparedNext = item
            guard let address = self.resolver.addressToWarm(for: item) else { return }
            let warmed = await AetherEngine.prewarm(url: address)
            if let declined = warmed.declined {
                Self.log.notice("Didn't warm the next episode: \(declined, privacy: .public)")
            }
        }
    }

    /// Ends the session for good, as the player is dismissed.
    func close() async {
        guard !isClosed else { return }
        countdownTask?.cancel()
        noticeTask?.cancel()
        chipTask?.cancel()
        similarTask?.cancel()
        retryHoldTask?.cancel()
        nextPreparation?.cancel()
        artworkTask?.cancel()
        seekWait?.cancel()
        loads.cancel()
        scrubbing.finish()
        finishSession(status == .ended ? .reachedEnd : .left(toNextEpisode: false))
        isClosed = true
        subscriptions.removeAll()
        // Warmed for a next episode that won't play now.
        AetherEngine.discardPrewarmedSources()
        if lease.holder == id {
            lease.holder = nil
            engine.stop()
        }
        onClose?()
    }

    /// Lets go of the session's resources and tells the server where playback stopped, and stops
    /// its transcode. The telling doesn't hold up what plays next, as on a slow connection it can
    /// take seconds; the next session's start waits for it instead, so the server hears them in
    /// order. A session that never got as far as telling the server it started has nothing to
    /// stop there. `current` stays, for the controls. Safe to call twice.
    ///
    /// The server hears the title played to its end when it did, and when the viewer leaves it
    /// in its credits, or moves on to the next episode while the up-next card offers it
    /// (`TitleEnding.finishes`), so it's marked watched rather than left a few minutes from the end.
    private func finishSession(_ end: SessionEnd) {
        let finished = switch end {
        case .reachedEnd: true
        case .left(let toNextEpisode): ending.finishes(leavingAt: clock.time, toNextEpisode: toNextEpisode && nextEpisode != nil)
        case .interrupted: false
        }
        // The stop waits for the periodic report in flight, and the title's position it gives, so
        // nothing lands after the stop that finished the title and marked it watched.
        let progress = reportTask
        reportTask?.cancel()
        reportTask = nil
        watchTask?.cancel()
        watchTask = nil
        seekWait?.cancel()
        seekWait = nil
        unregisterRemoteCommands()
        Self.keepScreenAwake(false)
        guard let current = session else { return }
        sessionIsOpen = false
        nowPlayingChanged()
        current.scopedURL?.stopAccessingSecurityScopedResource()
        let position = finished ? (duration > 0 ? duration : clock.time) : clock.time
        let previousReport = stopReport
        let wasReported = progress != nil
        // Immediate: the report reads this session's length and pause before the next one starts.
        stopReport = Task.immediate {
            if !wasReported {
                // Still in order behind the stop before.
                await previousReport?.value
            } else if await self.report(.stopped, for: current, position: position, after: [previousReport, progress]) {
                await self.giveTitleThePosition(of: current)
            }
            guard current.isTranscode, let reporting = current.reporting, let client = self.accounts.client else { return }
            do {
                try await client.stopTranscoding(playSessionId: reporting.playSessionId)
            } catch {
                Self.log.notice("Couldn't stop the server's transcode: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// How a session ends, which decides the position the server hears (`finishSession`).
    private enum SessionEnd {
        /// The stream played to its end.
        case reachedEnd
        /// The viewer left the title: closed the player, or moved to another title, the next
        /// episode when `toNextEpisode`.
        case left(toNextEpisode: Bool)
        /// Another stream of the title takes over, or it failed: where it got to.
        case interrupted
    }

    // MARK: Reporting

    private enum ReportKind { case started, progress, stopped }

    private func startReporting() {
        reportTask?.cancel()
        guard let current = session else { return }
        if let reporting = current.reporting {
            playedTitleIds.insert(reporting.itemId)
            if let seriesId = current.item?.seriesId { playedTitleIds.insert(seriesId) }
        }
        // Read now: the stop `finishSession` makes for this session waits for this task, which
        // would then wait for it in turn and never report again.
        let previousStop = stopReport
        reportTask = Task { [weak self] in
            await self?.report(.started, for: current, position: current.startPosition ?? 0, after: [previousStop])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if self.status == .playing || self.status == .paused || self.status == .buffering,
                   await self.report(.progress, for: current, position: self.clock.time), !Task.isCancelled {
                    await self.giveTitleThePosition(of: current)
                }
            }
        }
    }

    private func reportPauseChange(paused: Bool) {
        guard startedReporting, lastReportedPaused != paused else { return }
        lastReportedPaused = paused
        reportProgressNow()
    }

    /// Tells the server at once, for a remote following this playback: after a pause, a seek or
    /// a change of track.
    private func reportProgressNow() {
        guard let current = session, startedReporting else { return }
        Task { await report(.progress, for: current, position: clock.time) }
    }

    /// Tells the server, once the `earlier` reports have, and keeps the position here. A server
    /// that can't be reached is told later, by `WatchHistory.syncPending`. Says whether the server
    /// was told.
    @discardableResult
    private func report(_ kind: ReportKind, for playback: ResolvedPlayback, position: Double,
                        after earlier: [Task<Void, Never>?] = []) async -> Bool {
        let total = duration > 0 ? duration : playback.duration
        let isPaused = status == .paused
        let isCurrent = current?.reporting?.playSessionId == playback.reporting?.playSessionId
        let audioStream = isCurrent ? audioStreamIndex : nil
        let subtitleStream = isCurrent ? subtitleStreamIndex : nil
        for report in earlier { await report?.value }
        var delivered = false
        if let reporting = playback.reporting, let client = accounts.client {
            let report = PlaybackReport(
                ItemId: reporting.itemId,
                MediaSourceId: reporting.mediaSourceId,
                PlaySessionId: reporting.playSessionId,
                PlayMethod: reporting.playMethod,
                PositionTicks: Int64(max(0, position) * 10_000_000),
                IsPaused: isPaused,
                AudioStreamIndex: audioStream,
                SubtitleStreamIndex: subtitleStream
            )
            do {
                switch kind {
                case .started:
                    try await client.reportPlaybackStart(report)
                    startedReporting = true
                case .progress: try await client.reportPlaybackProgress(report)
                case .stopped: try await client.reportPlaybackStopped(report)
                }
                delivered = true
            } catch {
                Self.log.notice("Couldn't report playback: \(error.localizedDescription, privacy: .public)")
            }
        }
        // A start says nothing new about the position.
        guard kind != .started else { return delivered }
        let isServerItem = playback.reporting != nil
        history.record(key: playback.historyKey, position: position, duration: total, needsSync: isServerItem && !delivered)
        return delivered
    }

    /// Gives the title the position the server keeps for the version playing, when that isn't the
    /// title's own (after a step down, for a version picked, for another remote stream),
    /// so lists, Smart Downloads and other clients see where the title got to. Playback goes on
    /// as it is when the server doesn't take it.
    private func giveTitleThePosition(of playback: ResolvedPlayback) async {
        guard let reporting = playback.reporting, let versionId = reporting.mediaSourceId, versionId != reporting.itemId,
              let client = accounts.client, let account = accounts.account else { return }
        do {
            try await client.givePosition(ofVersion: versionId, toItem: reporting.itemId, userId: account.userId)
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("""
                Couldn't give \(reporting.itemId, privacy: .public) the position of its version \(versionId, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: Now Playing

    /// On iPhone, iPad and Apple TV the engine's Now Playing session carries the card and the
    /// remote commands; on the Mac and Vision Pro they go to the shared system centers.
    private var commandCenter: MPRemoteCommandCenter? {
        #if os(iOS) || os(tvOS)
        engine.videoNowPlayingSession?.remoteCommandCenter
        #else
        MPRemoteCommandCenter.shared()
        #endif
    }

    /// What's playing, for the system's Now Playing card and remotes, and for AVKit's info pane and
    /// AirPlay receivers: the title, an episode's show and number, its description, and its
    /// picture once that's loaded.
    private func setNowPlaying(_ playback: ResolvedPlayback) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: playback.title]
        if let item = playback.item, item.isEpisode {
            if let show = item.seriesName { info[MPMediaItemPropertyArtist] = show }
            if let number = Self.nowPlayingEpisodeNumber(item) { info[MPMediaItemPropertyAlbumTitle] = number }
        } else if let subtitle = playback.subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        let artwork = playback.item.flatMap { item in nowPlayingArtwork?.itemId == item.id ? nowPlayingArtwork : nil }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork.artwork }
        #if os(iOS) || os(tvOS)
        engine.setVideoNowPlayingInfo(info)
        #else
        nowPlayingIdentity = info
        publishNowPlaying()
        #endif
        var metadata = [Self.metadataItem(.commonIdentifierTitle, playback.title as NSString)]
        if let overview = playback.item?.overview, !overview.isEmpty {
            metadata.append(Self.metadataItem(.commonIdentifierDescription, overview as NSString))
        }
        if let jpeg = artwork?.jpeg {
            let picture = Self.metadataItem(.commonIdentifierArtwork, jpeg as NSData)
            picture.dataType = kCMMetadataBaseDataType_JPEG as String
            metadata.append(picture)
        }
        engine.setExternalMetadata(metadata)
        if artwork == nil, let item = playback.item { loadNowPlayingArtwork(of: item) }
    }

    /// Loads the episode's still, or the title's backdrop, and puts it on Now Playing while the
    /// title is still on screen.
    private func loadNowPlayingArtwork(of item: JellyfinItem) {
        guard let address = accounts.session?.landscape(item, width: Self.nowPlayingArtworkWidth) else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            let image: PlatformImage
            do {
                image = try await ImagePipeline.shared.image(for: address)
            } catch {
                if !error.isCancellation {
                    Self.log.notice("Couldn't load the Now Playing picture: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.nowPlayingArtwork = NowPlayingArtwork(itemId: item.id, image: image)
            if let current = self.current, current.item?.id == item.id { self.setNowPlaying(current) }
        }
    }

    private static let nowPlayingArtworkWidth = 1280

    /// An episode's number for Now Playing's album line: "S1, E2", "S1, E2–3".
    static func nowPlayingEpisodeNumber(_ item: JellyfinItem) -> String? {
        guard let number = item.indexNumber else { return nil }
        var episode = "E\(number)"
        if let end = item.indexNumberEnd, end > number { episode += "–\(end)" }
        guard let season = item.parentIndexNumber else { return episode }
        return "S\(season), \(episode)"
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    #if !(os(iOS) || os(tvOS))
    @ObservationIgnored private var nowPlayingIdentity: [String: Any] = [:]

    /// The system keeps the clock running from the elapsed time and rate given here, so it is
    /// republished whenever either changes.
    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard session != nil else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = nowPlayingIdentity
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.time
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
    #endif

    private func nowPlayingChanged() {
        #if !(os(iOS) || os(tvOS))
        publishNowPlaying()
        #endif
    }

    private func registerRemoteCommands() {
        unregisterRemoteCommands()
        guard let center = commandCenter else { return }
        func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: handler)))
        }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.playCommand) { [weak self] _ in self?.play(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        // Siri asks for its own interval ("skip ahead two minutes"); the buttons for the preferred one.
        add(center.skipForwardCommand) { [weak self] event in
            self?.skip(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval)
            return .success
        }
        add(center.skipBackwardCommand) { [weak self] event in
            self?.skip(by: -((event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval))
            return .success
        }
        #if os(tvOS)
        // A TV remote's held fast-forward and rewind, through HDMI-CEC, scan as the Siri Remote's
        // held clickpad does, and land where they're let go.
        add(center.seekForwardCommand) { [weak self] event in self?.seekCommand(event, forward: true) ?? .commandFailed }
        add(center.seekBackwardCommand) { [weak self] event in self?.seekCommand(event, forward: false) ?? .commandFailed }
        #endif
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    #if os(tvOS)
    private func seekCommand(_ event: MPRemoteCommandEvent, forward: Bool) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPSeekCommandEvent else { return .commandFailed }
        switch event.type {
        case .beginSeeking: beginScan(forward: forward)
        case .endSeeking: if scrubbing.isScanning { commitScrub() }
        @unknown default: return .commandFailed
        }
        return .success
    }
    #endif

    private func unregisterRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
    }

    // MARK: Helpers

    static func keepScreenAwake(_ awake: Bool) {
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static func trackTitle(_ track: TrackInfo) -> String {
        let language = languageName(track.language)
        let name = TrackChooser.ownName(of: track) ?? ""
        var title = language ?? (name.isEmpty ? "Track \(track.id)" : name)
        if let language, !name.isEmpty, name.lowercased() != language.lowercased(), !name.lowercased().hasPrefix(language.lowercased()) {
            title += " (\(name))"
        }
        if track.isForced { title += " · Forced" }
        if track.isHearingImpaired { title += " · SDH" }
        if track.isCommentary { title += " · Commentary" }
        // A title that says so already shows in it.
        if track.isVisualImpaired, !AccessibleMedia.namesAudioDescription(title) { title += " · Audio Description" }
        return title
    }

    static func audioDetail(_ track: TrackInfo) -> String {
        var parts = [codecName(track.codec, profile: track.profile)]
        if let layout = channelLayoutName(track.channels) { parts.append(layout) }
        if track.isAtmos { parts.append("Atmos") }
        if track.isDTSX { parts.append("DTS:X") }
        return parts.joined(separator: " ")
    }

    static func subtitleDetail(_ track: TrackInfo) -> String {
        var parts = [codecName(track.codec, profile: nil)]
        if track.isExternal { parts.append("External") }
        return parts.joined(separator: " · ")
    }

    static func streamTitle(_ stream: MediaStream) -> String {
        var title = languageName(stream.language) ?? stream.title ?? stream.displayTitle ?? "Track \(stream.index ?? 0)"
        if stream.isForced == true { title += " · Forced" }
        if stream.isHearingImpaired == true { title += " · SDH" }
        if stream.isAudioDescription, !AccessibleMedia.namesAudioDescription(title) { title += " · Audio Description" }
        return title
    }

    static func codecName(_ codec: String, profile: String?) -> String {
        if let profile, profile.contains("Atmos") || profile.contains("DTS:X") || profile.contains("DTS-HD") { return profile }
        switch codec.lowercased() {
        case "eac3": return "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "truehd": return "Dolby TrueHD"
        // FFmpeg calls DTS "dca", after its Coherent Acoustics core.
        case "dts", "dca": return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "mp2": return "MP2"
        case "vorbis": return "Vorbis"
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt", "vtt": return "WebVTT"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub": return "VobSub"
        case "dvb_subtitle", "dvbsub": return "DVB"
        case "mov_text": return "Text"
        case let pcm where pcm.hasPrefix("pcm_"): return "PCM"
        default: return codec.uppercased()
        }
    }

    static func channelLayoutName(_ channels: Int) -> String? {
        switch channels {
        case 0: nil
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }
}
