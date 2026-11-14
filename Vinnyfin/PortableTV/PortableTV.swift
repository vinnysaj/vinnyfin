#if os(macOS)
import AppKit
import Observation

/// The Mac as an Apple TV, for a TV it's plugged into: a window full screen there, with the
/// library made for across the room, YouTube's website, and the player, driven by a remote.
/// The remote is vinnyfin on an iPhone, whose presses come through the server like any other
/// remote control, so it works on any network both reach the server from; the Mac's own keys
/// work too. While it's on the Mac stays awake, and the server lists it as a TV.
@Observable
final class PortableTV {
    /// Its window is open.
    private(set) var isOn = false
    private(set) var space = TVSpace.library {
        didSet { if isOn, space != oldValue { socket.capabilities = .portableTV(showing: space) } }
    }
    /// The playback on the TV, over the library or YouTube.
    private(set) var playing: PlayerModel?
    /// Counts the presses that show the player's controls, which it shows on each.
    private(set) var controlsRequests = 0
    let browser: TVBrowser
    let youTube = YouTubeTV()

    @ObservationIgnored private let player: PlayerCoordinator
    @ObservationIgnored private let socket: SessionSocket
    /// Keeps the Mac and its display awake while the TV is on.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    init(accounts: AccountStore, player: PlayerCoordinator, socket: SessionSocket) {
        self.player = player
        self.socket = socket
        browser = TVBrowser(accounts: accounts) { [player] request in player.open(request) }
    }

    /// As its window opens: playbacks play on the TV, remotes find it, and the Mac stays awake.
    func turnOn() {
        guard !isOn else { return }
        isOn = true
        player.playsOnTV = true
        socket.capabilities = .portableTV(showing: space)
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Portable TV is on")
    }

    /// As its window closes, which stops what it plays.
    func turnOff() async {
        guard isOn else { return }
        isOn = false
        player.playsOnTV = false
        socket.capabilities = ClientCapabilities()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        youTube.pauseVideos()
        await stopPlaying()
    }

    // MARK: Commands

    /// Does what a remote asked when it's the TV's to do, and says whether it was: every press,
    /// and while YouTube shows, the transport, which YouTube's own keys do. The rest is for the player.
    func handle(_ command: RemoteCommand) -> Bool {
        if case .tv(let press) = command {
            // Presses for a TV that's been turned off do nothing.
            if isOn { self.press(press) }
            return true
        }
        guard isOn, space == .youTube, playing == nil else { return false }
        switch command {
        case .togglePause: youTube.press(key: .playPause)
        case .skip(let seconds): youTube.press(key: seconds < 0 ? .back10 : .forward10)
        case .unpause, .pause, .stop, .seek, .nextEpisode, .previousEpisode, .audioStream, .subtitleStream: break
        // Plays on the TV, over YouTube.
        case .play, .tv: return false
        }
        return true
    }

    func press(_ press: TVPress) {
        // The pointer that YouTube's remote moves draws itself; the Mac's stays out of the way.
        NSCursor.setHiddenUntilMouseMoves(true)
        switch press {
        case .home(let target):
            Task { await stopPlaying() }
            let target = target ?? space
            if target == space {
                switch space {
                case .library: browser.goHome()
                case .youTube: youTube.goHome()
                }
            } else {
                show(target)
            }
        case .text(let text):
            guard playing == nil else { return }
            switch space {
            case .library: browser.searchFor(text)
            case .youTube: youTube.search(text)
            }
        default:
            if let playing {
                pressDuringPlayback(press, playing)
            } else {
                switch space {
                case .library: browser.press(press)
                case .youTube: youTube.press(press)
                }
            }
        }
    }

    /// Switches between the library and YouTube, each where it was left.
    func show(_ space: TVSpace) {
        if space != .youTube { youTube.pauseVideos() }
        self.space = space
    }

    /// Select plays and pauses, left and right skip back and ahead, up and down bring the
    /// controls up, and Back stops, as on Apple TV.
    private func pressDuringPlayback(_ press: TVPress, _ model: PlayerModel) {
        switch press {
        case .select: model.togglePlayPause()
        case .left: model.skip(by: -PlayerModel.skipInterval)
        case .right: model.skip(by: PlayerModel.skipInterval)
        case .back:
            Task { await stopPlaying() }
            return
        case .up, .down, .home, .text, .point, .click, .scroll, .fullScreen: break
        }
        controlsRequests += 1
    }

    // MARK: Playing

    /// Plays on the TV in place of what played there. The one engine plays one thing, so the
    /// caller closes any player window.
    func play(_ request: PlaybackRequest) {
        let previous = playing
        playing = nil
        if let previous, player.presented === previous { player.presented = nil }
        youTube.pauseVideos()
        if let model = player.makeModel(for: request) {
            player.presented = model
            playing = model
        }
        Task { await previous?.close() }
    }

    func stopPlaying() async {
        guard let model = playing else { return }
        playing = nil
        if player.presented === model { player.presented = nil }
        await model.close()
    }
}
#endif
