import SwiftUI
#if os(iOS) || os(macOS)
import AetherEngine
import AVKit
import Combine
import OSLog
#endif

/// What the player's Picture in Picture button shows and does.
struct PictureInPictureButton {
    /// The window can start now.
    let isPossible: Bool
    /// The window is up, which the button closes.
    let isActive: Bool
    let toggle: () -> Void
}

#if os(iOS) || os(macOS)
/// Picture in Picture for whichever layer the engine draws into: AVPlayer's on the native path,
/// the sample-buffer layer on the software path. The app has one, which the player coordinator
/// keeps, so the window outlives the player it started from: on iPhone and iPad the player goes
/// away while the window plays (`PlayerCoordinator.isInPictureInPicture`). The playback hands its
/// subtitles to the system while the window is up, where the overlay isn't drawn.
@Observable
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var isPossible = false
    private(set) var isActive = false
    /// Told once the window has the picture.
    @ObservationIgnored var onStart: (() -> Void)?
    /// Asked to bring the player back as the window's restore button is pressed. It calls the
    /// completion once the player is on screen to take the picture back, with false when it isn't.
    @ObservationIgnored var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    /// Told as the window closes by its own close button, the player not coming back.
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var model: PlayerModel?
    @ObservationIgnored private weak var engine: AetherEngine?
    @ObservationIgnored private var attachedLayer: AnyObject?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    /// Tells the sample-buffer window of the software path's pauses, plays and length.
    @ObservationIgnored private var playbackChanges: AnyCancellable?
    /// The window is stopping because a player is coming back for the picture.
    @ObservationIgnored private var isRestoring = false
    /// The window is stopping because its playback ended; nothing comes back for it.
    @ObservationIgnored private var isClosing = false

    private nonisolated static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    /// Builds the controller for the layer the playback's engine is drawing into now.
    func attach(to model: PlayerModel) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.model = model
        let engine = model.engine
        self.engine = engine
        let controller: AVPictureInPictureController?
        if let layer = engine.nativePlayerLayer {
            guard attachedLayer !== layer else { return }
            attachedLayer = layer
            playbackChanges = nil
            controller = AVPictureInPictureController(playerLayer: layer)
        } else if let source = engine.softwarePiPSource {
            guard attachedLayer !== source.layer else { return }
            attachedLayer = source.layer
            controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: self))
            // AVKit asks whether it's paused, and how long it is, only when told it changed: a
            // pause from the Lock Screen, AirPods, Siri or the group, and the end of a title,
            // would leave the window's button and progress wrong. AVPlayer's layer tells it itself.
            playbackChanges = engine.$state.map { _ in () }.merge(with: engine.$duration.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak controller] in controller?.invalidatePlaybackState() }
        } else {
            return
        }
        controller?.delegate = self
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        self.controller = controller
        possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    /// The button's state, and its action: starting the window, or bringing the player back from
    /// it. Nil on a device without Picture in Picture, where a button could never be used.
    var button: PictureInPictureButton? {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        return PictureInPictureButton(isPossible: isPossible, isActive: isActive) { [weak self] in self?.toggle() }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    /// Closes the window, as its playback ends, without bringing a player back for it.
    func close() {
        guard let controller, controller.isPictureInPictureActive else { return }
        isClosing = true
        controller.stopPictureInPicture()
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = true
            self.model?.pictureLeavesApp(true)
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.onStart?() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        Self.log.error("Picture in Picture didn't start: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            self.engine?.pictureInPictureActive = false
            self.model?.pictureLeavesApp(false)
            self.isActive = false
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // AVKit asks on the main thread, and takes the answer on any.
        nonisolated(unsafe) let completion = completionHandler
        MainActor.assumeIsolated {
            guard !isClosing, let onRestore else {
                completion(!isClosing)
                return
            }
            isRestoring = true
            onRestore(completion)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = false
            self.model?.pictureLeavesApp(false)
            self.isActive = false
            let closedByItself = !self.isRestoring && !self.isClosing
            self.isRestoring = false
            self.isClosing = false
            if closedByItself { self.onClose?() }
        }
    }

    // Sample-buffer playback, answered from the engine's software source.

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.engine?.softwarePiPSource?.setPlaying(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated { engine?.softwarePiPSource?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { engine?.softwarePiPSource?.isPaused ?? true }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        await MainActor.run { engine?.softwarePiPSource?.skip(by: skipInterval.seconds) }
    }
}
#endif
