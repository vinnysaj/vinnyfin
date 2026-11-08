import AVFoundation
import Foundation
import MediaPlayer
import Observation
import OSLog

/// Sounds: white noise, fans, rain and waves to fall asleep or settle down to, made on the device
/// as they play (`SoundSynthesizer`), with a sleep timer. It plays like any audio app: on the Lock
/// Screen and in Control Center, on with the screen locked, paused by calls, by other apps' audio
/// and when the headphones it plays on are unplugged.
///
/// - The person plays, pauses, stops and picks the sound in Sounds (`SoundsView`), and plays,
///   pauses and moves to the next or previous sound from the Lock Screen.
/// - A video steps it aside: it goes quiet while the player is open, handing the video the audio
///   session (`SoundOutput`), and carries on once the player closes.
/// - The sleep timer stops it, fading out, after a while or once downloads finish, and is off
///   again after; stopping turns it off too. A timer of minutes counts from when it's chosen, or
///   from play, paused or not.
/// - Calls, Siri and alarms pause it, and it carries on when the system recommends it.
@Observable
final class SoundPlayer {
    enum State: Equatable, Sendable {
        case stopped
        case playing
        case paused
    }

    /// What the person, the Lock Screen or the system last made it: playing still while a video
    /// steps it aside.
    private(set) var state = State.stopped
    private(set) var timer = SleepTimer.off
    /// When a timer of minutes stops it; nil until it plays, and for other timers.
    private(set) var deadline: Date?
    /// A video's player is open, and has the audio.
    private(set) var isSteppedAside = false
    /// Why it couldn't play or let go of the audio, to show in Sounds until dismissed.
    var problem: String?

    var sound: Sound { settings.sound }

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "sounds")

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let player: PlayerCoordinator
    #if !os(tvOS)
    @ObservationIgnored private let downloads: DownloadManager
    #endif
    @ObservationIgnored private let output = SoundOutput()
    /// Numbers each instruction to `output`, which drops any older than one it has carried out.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var timing: Task<Void, Never>?
    /// A call or another app paused it, and the system may recommend carrying on.
    @ObservationIgnored private var wasInterrupted = false
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var sessionObservations: [any NSObjectProtocol] = []
    #if !os(macOS)
    @ObservationIgnored private var sessionMessages: [NotificationCenter.ObservationToken] = []
    #endif

    #if os(tvOS)
    init(settings: AppSettings, player: PlayerCoordinator) {
        self.settings = settings
        self.player = player
    }
    #else
    init(settings: AppSettings, player: PlayerCoordinator, downloads: DownloadManager) {
        self.settings = settings
        self.player = player
        self.downloads = downloads
    }
    #endif

    /// Follows the video player, the downloads and the audio session for the life of the app.
    func run() async {
        followSession()
        await withDiscardingTaskGroup { group in
            group.addTask { await self.followPlayer() }
            #if !os(tvOS)
            group.addTask { await self.followDownloads() }
            #endif
        }
    }

    // MARK: Controls

    /// Plays `sound`, or the one chosen last.
    func play(_ sound: Sound? = nil) {
        if let sound { settings.sound = sound }
        wasInterrupted = false
        problem = nil
        if state == .stopped, case .minutes(let minutes) = timer { setDeadline(minutes) }
        state = .playing
        apply()
    }

    func pause() {
        guard state == .playing else { return }
        wasInterrupted = false
        state = .paused
        apply()
    }

    func togglePlayPause() {
        state == .playing ? pause() : play()
    }

    /// Stops it, and turns the sleep timer off.
    func stop() {
        stop(fadingOut: false)
    }

    /// The sleep timer from now on: a timer of minutes counts from now while it plays or is
    /// paused, and from play while it's stopped.
    func setTimer(_ timer: SleepTimer) {
        self.timer = timer
        if case .minutes(let minutes) = timer, state != .stopped {
            setDeadline(minutes)
        } else {
            setDeadline(nil)
        }
        #if !os(tvOS)
        if timer == .whenDownloadsFinish { downloadsChanged(hasDownloads: Self.hasDownloads(downloads)) }
        #endif
    }

    private func stop(fadingOut: Bool) {
        guard state != .stopped else { return }
        wasInterrupted = false
        state = .stopped
        timer = .off
        setDeadline(nil)
        apply(fadingOut: fadingOut && !isSteppedAside)
    }

    // MARK: Output

    /// What the output does for `state`: a video's player that's open has the audio, whether the
    /// sound was playing or paused.
    nonisolated static func target(for state: State, sound: Sound, isSteppedAside: Bool) -> SoundOutput.Target {
        switch state {
        case .playing: isSteppedAside ? .handedOver : .playing(sound)
        case .paused: isSteppedAside ? .handedOver : .paused
        case .stopped: .stopped
        }
    }

    private func apply(rebuild: Bool = false, fadingOut: Bool = false) {
        revision += 1
        let revision = revision
        let target = Self.target(for: state, sound: sound, isSteppedAside: isSteppedAside)
        Self.log.info("\(String(describing: target), privacy: .public)\(rebuild ? ", rebuilt" : "", privacy: .public)\(fadingOut ? ", fading out" : "", privacy: .public)")
        publishNowPlaying()
        let output = output
        Task {
            do {
                try await output.apply(target, revision: revision, rebuild: rebuild, fadingOut: fadingOut)
            } catch {
                guard revision == self.revision else { return }
                Self.log.error("Couldn't \(String(describing: target), privacy: .public): \(String(describing: error), privacy: .public)")
                switch target {
                case .playing(let sound):
                    problem = "Couldn't play \(sound.name): \(error.localizedDescription)"
                    state = .paused
                    publishNowPlaying()
                case .paused:
                    break
                case .handedOver:
                    problem = "Couldn't hand the audio to the video, so the video may play quieter: \(error.localizedDescription)"
                case .stopped:
                    problem = "Couldn't let go of the audio, so other apps may stay quieter: \(error.localizedDescription)"
                }
            }
        }
    }

    private func followPlayer() async {
        let player = player
        for await isOpen in Observations({ player.presented != nil }) {
            guard isOpen != isSteppedAside else { continue }
            isSteppedAside = isOpen
            guard state != .stopped else { continue }
            apply()
        }
    }

    // MARK: Sleep timer

    private func setDeadline(_ minutes: Int?) {
        timing?.cancel()
        guard let minutes else {
            deadline = nil
            return
        }
        let deadline = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        self.deadline = deadline
        timing = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
            } catch {
                // Cancelled: the timer changed.
                return
            }
            self?.timerEnded()
        }
    }

    private func timerEnded() {
        Self.log.info("The sleep timer ended")
        stop(fadingOut: true)
    }

    #if !os(tvOS)
    private static func hasDownloads(_ downloads: DownloadManager) -> Bool {
        !DownloadJob.queue(downloads.jobs).isEmpty
    }

    private func followDownloads() async {
        let downloads = downloads
        for await hasDownloads in Observations({ Self.hasDownloads(downloads) }) {
            downloadsChanged(hasDownloads: hasDownloads)
        }
    }

    private func downloadsChanged(hasDownloads: Bool) {
        guard timer == .whenDownloadsFinish, state != .stopped, !hasDownloads else { return }
        timerEnded()
    }
    #endif

    // MARK: Lock Screen

    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard state != .stopped, !isSteppedAside else {
            unregisterCommands()
            // A video's Now Playing session carries its card on iPhone, iPad and Apple TV; on the
            // Mac and Vision Pro the video publishes over this.
            #if os(iOS) || os(tvOS)
            center.nowPlayingInfo = nil
            #else
            if state == .stopped { center.nowPlayingInfo = nil }
            #endif
            #if !os(tvOS)
            if state == .stopped { center.playbackState = .stopped }
            #endif
            return
        }
        registerCommands()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: sound.name,
            MPMediaItemPropertyArtist: "vinnyfin",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        #if !os(tvOS)
        center.playbackState = state == .playing ? .playing : .paused
        #endif
    }

    private func registerCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget { _ in
                action()
                return .success
            }))
        }
        add(center.playCommand) { [weak self] in self?.play() }
        add(center.pauseCommand) { [weak self] in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in self?.togglePlayPause() }
        add(center.nextTrackCommand) { [weak self] in
            guard let self else { return }
            play(sound.next)
        }
        add(center.previousTrackCommand) { [weak self] in
            guard let self else { return }
            play(sound.previous)
        }
    }

    /// Takes these commands back. Next and previous, which a video doesn't use, are turned off
    /// for its card; play and pause stay as a video may have turned them on.
    private func unregisterCommands() {
        guard !commandTargets.isEmpty else { return }
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    // MARK: Audio session

    /// Interruptions, resets, changes of output and the engine stopping.
    private func followSession() {
        let center = NotificationCenter.default
        #if os(macOS)
        sessionObservations = [
            // The engine stops when its output changes.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.outputChanged() }
            },
        ]
        #else
        let session = AVAudioSession.sharedInstance()
        sessionMessages = [
            center.addObserver(of: session, for: .didBecomeInactive) { [weak self] message in
                guard case .systemInterruption = message.deactivationResult else { return }
                self?.interrupted()
            },
            center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] message in
                self?.interruptionEnded(shouldResume: message.recommendation == .shouldResume)
            },
        ]
        sessionObservations = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
                MainActor.assumeIsolated { self?.routeChanged(reason) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.outputChanged() }
            },
            // The engine stops when its output's format changes, as with a new route.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.outputChanged() }
            },
        ]
        #endif
    }

    #if !os(macOS)
    private func interrupted() {
        guard state == .playing, !isSteppedAside else { return }
        Self.log.notice("Interrupted")
        state = .paused
        wasInterrupted = true
        publishNowPlaying()
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard wasInterrupted, state == .paused else { return }
        Self.log.notice("Interruption over; the system \(shouldResume ? "recommends" : "doesn't recommend", privacy: .public) carrying on")
        wasInterrupted = false
        if shouldResume { play() }
    }

    /// Pauses when the output it played to goes away, as with headphones unplugged, rather than
    /// carrying on out loud.
    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable, state == .playing, !isSteppedAside else { return }
        Self.log.info("The output went away; pausing")
        pause()
    }
    #endif

    /// The engine stopped or the media services were reset: playing, it's built anew.
    private func outputChanged() {
        guard state == .playing, !isSteppedAside else { return }
        Self.log.info("The output changed; rebuilding")
        apply(rebuild: true)
    }
}

/// When the sleep timer stops Sounds.
nonisolated enum SleepTimer: Hashable, Identifiable, Sendable {
    case off
    case minutes(Int)
    #if !os(tvOS)
    case whenDownloadsFinish
    #endif

    var id: Self { self }

    static var choices: [SleepTimer] {
        var choices: [SleepTimer] = [.off] + [15, 30, 45, 60, 120, 240, 480].map(SleepTimer.minutes)
        #if !os(tvOS)
        choices.append(.whenDownloadsFinish)
        #endif
        return choices
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .minutes(let minutes) where minutes < 60: "\(minutes) Minutes"
        case .minutes(let minutes) where minutes == 60: "1 Hour"
        case .minutes(let minutes): "\(minutes / 60) Hours"
        #if !os(tvOS)
        case .whenDownloadsFinish: "When Downloads Finish"
        #endif
        }
    }
}
