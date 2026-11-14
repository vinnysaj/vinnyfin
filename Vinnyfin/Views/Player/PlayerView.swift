import AetherEngine
import AVKit
#if os(macOS)
import AppKit
#endif
#if os(visionOS)
import Combine
#endif
#if DEBUG
import OSLog
#endif
import SwiftUI

/// The player: the picture edge to edge, subtitles over it, and controls that fade away while
/// it plays. Tap (or move the mouse, or press a key) to bring them back; pinch to fill the
/// screen. On an iPhone Duo standing half open like a laptop the picture takes the top half and
/// the controls the bottom, with the show's episodes. On Vision Pro the window is the picture,
/// with the controls on glass below it, and the room dims while it plays; in the cinema the
/// picture moves to the big screen, a pinch there shows the controls, and the window stays,
/// clear, holding them. On Apple TV the remote scrubs: swipe or circle the clickpad to move the
/// timeline and click to jump there, click a side to skip, hold one to scan.
struct PlayerView: View {
    let model: PlayerModel
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerControlsRequests) private var controlsRequests
    @State private var controlsVisible = true
    /// The controls stay up until they're hidden the way they were shown. VoiceOver, Voice Control
    /// and Switch Control take longer to reach a control than the few seconds they'd stay.
    @State private var holdsControls = false
    /// Play On and SharePlay are up. Here rather than with the controls, which come and go under them.
    @State private var showsPlayElsewhere = false
    @State private var hideTask: Task<Void, Never>?
    @State private var fillsScreen = false
    @State private var panel: PlayerPanel?
    /// Where the controls' bottom bar starts, in global coordinates.
    @State private var bottomBarTop: CGFloat?
    /// Where the controls' top bar ends, in global coordinates.
    @State private var topBarBottom: CGFloat?
    /// Where the up-next card starts while it shows, in global coordinates.
    @State private var upNextCardTop: CGFloat?
    /// A title is starting: from asking for it until its first frame.
    @State private var isStartingTitle = true
    /// Why the playback failed, last time it did.
    @State private var failure = ""
    /// Try Again was pressed a moment ago. The failure stays up meanwhile, saying so, rather than
    /// flashing away and back when the new try fails at once.
    @State private var isRetrying = false
    #if os(iOS) || os(macOS)
    @State private var externalPlayback = ExternalPlayback()
    /// The AirPlay receiver that got only the sound, while that's being said.
    @State private var soundOnlyReceiver: String?
    @State private var soundOnlyTask: Task<Void, Never>?
    #endif
    #if os(macOS)
    @State private var pointerIsOver = false
    #endif
    #if os(tvOS)
    @FocusState private var focus: PlayerFocus?
    /// Try Again over a playback that failed, which takes focus from the controls as it appears.
    @FocusState private var retryFocused: Bool
    /// The controls show just the timeline, as the remote moves it while they were hidden.
    @State private var controlsCompact = false
    @State private var touchSurface = TouchSurface()
    /// Where the timeline was when the swipe under way started moving it, which a circle that
    /// began as the swipe goes back to.
    @State private var swipeStart: Double?
    #else
    @FocusState private var hasKeyboardFocus: Bool
    #endif
    #if os(iOS) || os(macOS)
    @State private var pictureInPicture = PictureInPicture()
    #endif
    #if os(iOS)
    @State private var orientationLock = PlayerOrientationLock()
    /// The fold across the screen of an iPhone Duo standing half open, in window coordinates.
    @State private var fold: CGRect?
    #else
    private let fold: CGRect? = nil
    #endif
    #if DEBUG
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")
    #endif

    var body: some View {
        ZStack {
            if showsPicture {
                #if !os(visionOS)
                // On Vision Pro the surface fills its own: RealityKit's picture draws behind the
                // window's views, so a fill here would hide it.
                Color.black
                    .ignoresSafeArea()
                    #if os(iOS)
                    .onGeometryChange(for: CGRect?.self) { Self.fold(in: $0) } action: { fold = $0 }
                    .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { orientationLock.windowChanged(isWide: $0) }
                    #endif
                #endif
                PlayerSurface(engine: model.engine)
                    .frame(height: fold?.minY)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .accessibilityIgnoresInvertColors()
                if let cover = pictureCover {
                    inPictureArea {
                        PlayerBackdrop(item: model.item,
                                       coveredBelow: PlayerLayout.coveredBelow(clearsControls ? bottomBarTop : nil, upNextCardTop)) {
                            coverCaption(cover)
                        }
                    }
                    .transition(.opacity)
                }
            }
            #if os(tvOS)
            if !controlsVisible {
                // Holds focus while the controls are hidden, so a click or a swipe up or down brings
                // them back; sideways the remote scrubs (`RemoteInput`). It sits beside the controls
                // rather than around them: a focused parent would keep focus from moving between
                // the controls.
                Color.clear
                    .ignoresSafeArea()
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focus, equals: .picture)
                    .onTapGesture { pictureClicked() }
                    .onMoveCommand { direction in
                        if direction == .up || direction == .down { showControls() }
                    }
                    .accessibilityLabel("Video")
                    .accessibilityHint("Shows the controls")
                    .accessibilityAction { showControls(holding: true) }
            }
            #else
            // Taps on the picture show and hide the controls; taps on a control stay with it.
            Color.clear
                .contentShape(.rect)
                .frame(height: fold?.minY)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
                // So VoiceOver, Voice Control ("Tap Video") and Switch Control, too, can bring back
                // controls that have faded; brought back that way, they stay.
                .accessibilityElement()
                .accessibilityLabel("Video")
                .accessibilityHint("Shows or hides the controls")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggleControls(holding: true) }
                .accessibilityIdentifier("player.picture")
                #if os(iOS)
                .gesture(MagnifyGesture().onEnded { pinched($0.magnification) })
                #endif
            #endif
            #if os(visionOS)
            // The controls are in an ornament below the window (see `controlsOrnament`).
            #else
            #if os(tvOS)
            if controlsVisible {
                PlayerControls(model: model, fillsScreen: $fillsScreen, panel: $panel,
                               bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                               onClose: onClose, onInteraction: scheduleHide, pictureInPicture: nil, playElsewhere: nil,
                               focus: $focus, isCompact: controlsCompact,
                               onTimelineSelect: timelineClicked, onTimelineMove: timelineMoved)
                    .transition(.opacity)
            }
            #else
            if let fold {
                PlayerControls(model: model, fillsScreen: $fillsScreen, panel: $panel,
                               bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                               onClose: onClose, onInteraction: {}, pictureInPicture: pictureInPictureAction,
                               playElsewhere: playElsewhereAction, isBelowFold: true)
                    .padding(.top, fold.maxY)
                    .ignoresSafeArea(edges: .top)
            } else if controlsVisible {
                PlayerControls(model: model, fillsScreen: $fillsScreen, panel: $panel,
                               bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                               onClose: onClose, onInteraction: scheduleHide, pictureInPicture: pictureInPictureAction,
                               playElsewhere: playElsewhereAction)
                    #if DEBUG
                    .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                        // Records a bottom inset that lifts the controls up the screen, such as a
                        // keyboard's or the screen's width less its height, as it comes.
                        Self.log.notice("Player controls' safe area insets: \(String(describing: insets), privacy: .public)")
                    }
                    #endif
                    .transition(.opacity)
            }
            #endif
            #endif
            #if os(iOS)
            if orientationLock.isAnnouncing, !showsControls {
                // Where it waits among the controls, so it seems to go back into them.
                RotateButton(onUse: scheduleHide)
                    .padding(.horizontal, Metrics.playerInset)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .motionTransition(.scale(scale: 0.6).combined(with: .opacity), reduceMotion: reduceMotion)
            }
            #endif
            // Over the controls' shading so captions stay bright; it takes no touches, and bottom
            // captions move up out of the way of the controls and the up-next card.
            if showsPicture {
                SubtitleOverlay(model: model, videoSize: fillsScreen ? nil : model.videoSize,
                                coveredBelow: PlayerLayout.coveredBelow(clearsControls ? bottomBarTop : nil, upNextCardTop))
                    .frame(height: fold?.minY)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
            inPictureArea { extras }
            // Over the controls, which stay up around it with nothing in it to act on.
            inPictureArea { statusOverlay }
            if let notice = model.notice {
                inPictureArea {
                    PlayerNotice(text: notice, controlsBottom: clearsControls ? topBarBottom : nil)
                }
                .motionTransition(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion)
            }
            #if os(iOS) || os(macOS)
            if let receiver = soundOnlyReceiver {
                inPictureArea {
                    AirPlaySoundOnlyNotice(receiverName: receiver, controlsBottom: clearsControls ? topBarBottom : nil)
                }
                .motionTransition(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion)
            }
            #endif
            if let panel {
                // Between the controls' bars, so the panel covers none of them. Where the band
                // between them is short, it has the height above the bottom bar.
                let clearsTopBar = clearsControls && !controlsAreShort
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    let top = clearsTopBar ? topBarBottom.map { max(0, $0 - frame.minY) } ?? 0 : 0
                    let bottom = clearsControls ? bottomBarTop.map { max(0, frame.maxY - $0) } ?? 60 : 60
                    TrackPanel(model: model, panel: panel, room: max(0, frame.height - top - bottom - 2 * Metrics.edge)) { closePanel() }
                        .padding(Metrics.edge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.top, top)
                        .padding(.bottom, bottom)
                }
                .motionTransition(.move(edge: .trailing).combined(with: .opacity), reduceMotion: reduceMotion)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.snappy, value: panel)
        .animation(.snappy, value: model.notice)
        // The first frame comes up through the title's picture.
        .animation(.easeInOut(duration: 0.5), value: pictureCover)
        // The player has no text input, so nothing it shows should make room for a keyboard: a
        // keyboard's region left from the screen before would lift the controls up the screen.
        .ignoresSafeArea(.keyboard)
        #if os(iOS) || os(macOS)
        .animation(.snappy, value: soundOnlyReceiver)
        .onAppear { externalPlayback.follow(model.engine) }
        .onChange(of: externalPlayback.pictureStaysLocal) { _, local in
            if local {
                tellSoundOnly()
            } else {
                soundOnlyTask?.cancel()
                soundOnlyReceiver = nil
            }
        }
        #endif
        #if os(visionOS)
        // The window has no glass of its own; the picture takes its rounded shape.
        .clipShape(.rect(cornerRadius: 46))
        .ornament(visibility: controlsVisible ? .visible : .hidden, attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            controlsOrnament
        }
        .preferredSurroundingsEffect(model.isPlaying && showsPicture ? .dark : nil)
        // A new picture is flat until the screen showing it finds otherwise.
        .onReceive(model.engine.$currentAVPlayer.removeDuplicates { $0 === $1 }) { _ in coordinator.pictureIsStereo = false }
        .onChange(of: coordinator.screenTaps) { toggleControls() }
        #endif
        #if os(iOS)
        .animation(.snappy, value: orientationLock.isAnnouncing)
        .animation(.smooth, value: fold)
        .environment(orientationLock)
        .onHingeChange { _, context in orientationLock.hingeChanged(isHalfOpen: context.hinge?.status == .partiallyOpen) }
        .onAppear { orientationLock.start() }
        .onDisappear { orientationLock.stop() }
        #endif
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                pointerIsOver = true
                showControls()
            case .ended:
                pointerIsOver = false
            }
        }
        // The window's close, minimize and zoom buttons go with the controls, off the picture.
        .background(WindowButtons(areHidden: !controlsVisible))
        #endif
        #if os(tvOS)
        .background {
            RemoteInput(surface: touchSurface, isActive: remoteDrivesTimeline, onGesture: remote)
        }
        .onPlayPauseCommand {
            // Moving the timeline, Play jumps there and plays.
            if model.scrubbing.isActive {
                model.commitScrub()
                model.play()
            } else {
                model.togglePlayPause()
            }
            showControls()
        }
        .onExitCommand {
            if model.scrubbing.isActive {
                // Back to where playback is.
                model.cancelScrub()
                scheduleHide()
            } else if panel != nil {
                closePanel()
            } else if controlsVisible, model.isPlaying {
                hideControls()
            } else if !controlsVisible, model.showsUpNext(at: model.clock.time) {
                // The up-next card goes first, as its Hide would.
                model.cancelUpNext()
            } else {
                onClose()
            }
        }
        // Hidden, the controls leave the remote to the picture; shown, it starts on the timeline,
        // or after a failure on Try Again.
        .onChange(of: controlsVisible) { _, visible in
            if visible, case .failed = model.status {
                retryFocused = true
            } else {
                focus = visible ? .timeline : .picture
            }
        }
        // Skips and scans from elsewhere, as Siri's or a TV remote's, show on the timeline too.
        .onChange(of: model.scrubbing.skipRun?.id) { _, run in
            if run != nil { revealTimeline() }
        }
        .onChange(of: model.scrubbing.isScanning) { _, scanning in
            if scanning { revealTimeline() }
        }
        #else
        // The player takes focus as it opens, for the Playback menu's keys (`PlayerCommand`) and
        // for the menu to act on it: a scene value doesn't reach the menu from the full-screen
        // cover the player is on iPhone and iPad.
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(keys: PlayerCommand.keys) { press in
            guard let command = PlayerCommand.pressed(press.key, modifiers: press.modifiers) else { return .ignored }
            perform(command)
            return .handled
        }
        .focusedValue(\.player, PlayerCommandTarget(model: model, fillsScreen: fillsScreen, perform: perform))
        .handoffPlayback(model)
        #endif
        #if os(iOS)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(.hidden)
        // On iPhone Duo the controls keep to the middle of the screen, where the picture is,
        // rather than making room for a vertical bar.
        .toolbarVerticalBehavior(.disabled)
        #endif
        // VoiceOver's two-finger scrub closes a panel, else the player, as the remote's Menu does.
        .accessibilityAction(.escape) {
            if panel != nil { closePanel() } else { onClose() }
        }
        .onChange(of: fillsScreen) { _, fills in model.engine.videoGravity = fills ? .resizeAspectFill : .resizeAspect }
        .onChange(of: model.status) { _, status in
            switch status {
            case .playing: scheduleHide()
            // Up for a new title, and for what the viewer acts on. A new stream of the same title
            // and a stall show in the picture, and leave the controls as they were.
            case .preparing, .paused, .ended, .failed: showControls(autoHide: false)
            case .loading, .buffering: break
            }
            // A new title starts over its picture until it plays, which it does only once its
            // first frame is up. A new stream of the same title keeps the picture it had. The
            // engine can pause on its way to the start position, and a playback watched together
            // waits paused for the group, so a pause doesn't end the start.
            switch status {
            case .preparing: isStartingTitle = true
            case .playing, .buffering, .ended: isStartingTitle = false
            case .loading, .paused, .failed: break
            }
            if case .failed(let message) = status {
                failure = message
                announce("Couldn't play this. \(message)")
                #if os(tvOS)
                // Once the card is up: focus can't go to a button that isn't there yet, and the
                // controls would keep it on the timeline.
                DispatchQueue.main.async { retryFocused = true }
                #endif
            }
            #if os(iOS) || os(macOS)
            pictureInPicture.attach(to: model.engine)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.restoreAfterBackground() }
            // Back from the background the picture can take a while to return; the controls show
            // meanwhile that playback carries on.
            if model.isPlaying { showControls() }
        }
        .onChange(of: model.notice) { _, notice in
            if let notice { announce(notice) }
        }
        // Turned on mid-playback, they'd need the controls to stay.
        .onChange(of: voiceOverEnabled || switchControlEnabled) { _, assisted in
            if assisted { hideTask?.cancel() }
        }
        // Portable TV's remote skipped, paused or asked for them.
        .onChange(of: controlsRequests) { showControls() }
        // Another device asked this one to stop.
        .onChange(of: coordinator.stopRequest) { _, request in
            guard request == model.id else { return }
            coordinator.stopRequest = nil
            onClose()
        }
        #if !os(tvOS)
        .sheet(isPresented: $showsPlayElsewhere) {
            PlayElsewhereSheet(subject: .playback(model), onHandedOver: onClose)
                // Half the screen, the picture still playing above it.
                .presentationDetents([.medium, .large])
        }
        #endif
        .task {
            #if !os(tvOS)
            hasKeyboardFocus = true
            #endif
            await model.start()
        }
        .preferredColorScheme(.dark)
    }

    #if os(tvOS)
    // MARK: Remote

    /// Whether the remote's swipes, circles and side clicks move the timeline: while the picture or
    /// the timeline has focus (or focus is between them, as the controls come up) and there's a
    /// timeline to move. On a button they're focus's, and VoiceOver has swipes of its own.
    private var remoteDrivesTimeline: Bool {
        guard panel == nil, !voiceOverEnabled, model.duration > 0 else { return false }
        switch model.status {
        case .playing, .paused, .buffering: break
        default: return false
        }
        switch focus {
        case .picture, .timeline, nil: return true
        default: return false
        }
    }

    private func remote(_ gesture: RemoteGesture) {
        switch gesture {
        case .lift:
            swipeStart = nil
            return
        case .holdEnded:
            // Let go, a scan lands where it got to.
            guard model.scrubbing.isScanning else { return }
            model.commitScrub()
            scheduleHide()
            return
        default:
            break
        }
        guard remoteDrivesTimeline else { return }
        let duration = model.duration
        switch gesture {
        case .swipe(let distance, let speed):
            if swipeStart == nil { swipeStart = model.scrubbing.position ?? model.clock.time }
            model.scrub(by: ScrubMotion.swipe(distance, speed: speed, duration: duration))
        case .circle(let turn, let undoesSwipe):
            if undoesSwipe, let swipeStart { model.scrubbing.position = swipeStart }
            model.scrub(by: ScrubMotion.circle(turn, duration: duration))
        case .click(let forward):
            // Playing, a click skips. Paused, or moving the timeline already, it steps the
            // timeline, for a click on the timeline or Play to jump there.
            let seconds = forward ? PlayerModel.skipInterval : -PlayerModel.skipInterval
            if model.scrubbing.isActive || !model.isPlaying { model.scrub(by: seconds) } else { model.skip(by: seconds) }
        case .holdBegan(let forward):
            model.beginScan(forward: forward)
        case .lift, .holdEnded:
            break
        }
        revealTimeline()
    }

    /// A click with the controls hidden takes the skip button's or up-next card's action when one
    /// shows, as it can't take focus from the picture; else it brings the controls up.
    private func pictureClicked() {
        if let forward = touchSurface.clickedSide(), remoteDrivesTimeline {
            remote(.click(forward: forward))
        } else if !performShownAction() {
            showControls()
        }
    }

    /// A click on the timeline jumps to where it was moved, or else plays or pauses.
    private func timelineClicked() {
        if let forward = touchSurface.clickedSide(), remoteDrivesTimeline {
            remote(.click(forward: forward))
            return
        }
        if model.scrubbing.isActive {
            model.commitScrub()
        } else {
            model.togglePlayPause()
        }
        scheduleHide()
    }

    /// Up from the timeline goes to the skip button or up-next card, down to the buttons; either
    /// brings the title and buttons back when the timeline showed alone. A swipe moving the
    /// timeline stays on it.
    private func timelineMoved(_ direction: MoveCommandDirection) {
        guard swipeStart == nil else { return }
        switch direction {
        case .up:
            if shownAction(at: model.clock.time) != nil {
                moveFocus(to: .action)
            } else {
                controlsCompact = false
            }
        case .down:
            controlsCompact = false
            moveFocus(to: .playPause)
        default:
            return
        }
        scheduleHide()
    }

    /// Moves focus from the move command under way, once it's done: focus changes during one are
    /// ignored.
    private func moveFocus(to target: PlayerFocus) {
        DispatchQueue.main.async { focus = target }
    }

    /// Brings the timeline up by itself while the controls are hidden; with them up, keeps them.
    private func revealTimeline() {
        if !controlsVisible {
            controlsCompact = true
            controlsVisible = true
        }
        scheduleHide()
    }
    #endif

    private enum ShownAction {
        case upNext(JellyfinItem)
        case skip(MediaSegment)
    }

    /// The up-next card in the credits, when there's a next episode, else the skip button.
    private func shownAction(at time: Double) -> ShownAction? {
        if model.showsUpNext(at: time), let next = model.nextEpisode { return .upNext(next) }
        if let segment = model.skippableSegment(at: time), segment.skipTitle != nil { return .skip(segment) }
        return nil
    }

    @discardableResult
    private func performShownAction() -> Bool {
        switch shownAction(at: model.clock.time) {
        case .upNext(let next): Task { await model.play(next) }
        case .skip(let segment): model.seek(to: segment.end)
        case nil: return false
        }
        return true
    }

    /// Below the fold the controls stay, off the picture.
    private var showsControls: Bool { controlsVisible || fold != nil }

    /// The controls show over the picture, so what's along its top and bottom keeps clear of
    /// their bars.
    private var clearsControls: Bool { controlsVisible && fold == nil && Self.controlsArePictureOverlay }

    /// The controls show over the picture with little height between their bars, nearly all of
    /// it the transport's in the middle: an iPhone on its side, a short window. Apple TV has no
    /// transport there.
    private var controlsAreShort: Bool {
        clearsControls && !Self.hasNoCenterButton && PlayerLayout.isShort(topBarBottom: topBarBottom, bottomBarTop: bottomBarTop)
    }

    private enum PictureCover: Equatable {
        case starting
        case airPlay(receiver: String)
    }

    /// Why the title's picture stands in for the video, when it does: the title is starting, or
    /// AirPlay has the video on another screen.
    private var pictureCover: PictureCover? {
        #if os(iOS) || os(macOS)
        if externalPlayback.isActive { return .airPlay(receiver: externalPlayback.receiverName) }
        #endif
        return isStartingTitle ? .starting : nil
    }

    @ViewBuilder private func coverCaption(_ cover: PictureCover) -> some View {
        switch cover {
        case .starting:
            ZStack {
                if let item = model.item { StartingTitle(item: item, isShort: controlsAreShort) }
            }
            .animation(.easeOut(duration: 0.3), value: model.item?.id)
        case .airPlay(let receiver):
            #if os(iOS) || os(macOS)
            AirPlayCaption(receiverName: receiver)
            #endif
        }
    }

    #if os(iOS) || os(macOS)
    /// Says for a few seconds that only the sound went to the AirPlay receiver.
    private func tellSoundOnly() {
        let receiver = externalPlayback.receiverName
        soundOnlyReceiver = receiver
        announce(AirPlaySoundOnlyNotice.message(receiver))
        soundOnlyTask?.cancel()
        soundOnlyTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { soundOnlyReceiver = nil }
        }
    }
    #endif

    /// In the cinema the picture and its subtitles are on the big screen instead.
    private var showsPicture: Bool {
        #if os(visionOS)
        !coordinator.isInCinema
        #else
        true
        #endif
    }

    /// The controls lie over the picture, so what's along its top and bottom moves out of their
    /// way. On Vision Pro they're below the window instead.
    private static var controlsArePictureOverlay: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    #if os(visionOS)
    private var controlsOrnament: some View {
        PlayerControls(model: model, fillsScreen: $fillsScreen, panel: $panel,
                       bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                       onClose: onClose, onInteraction: scheduleHide, pictureInPicture: nil, playElsewhere: playElsewhereAction)
            .padding(.top, 24)
    }
    #endif

    /// `content` over the picture: above the fold when there is one, else the whole screen.
    @ViewBuilder private func inPictureArea(@ViewBuilder _ content: () -> some View) -> some View {
        if let fold {
            content()
                .frame(height: fold.minY)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        } else {
            content()
        }
    }

    #if os(iOS)
    /// The fold across the window when an iPhone Duo stands half open like a laptop. Held like
    /// a book, the fold runs down the middle and the picture spans it.
    nonisolated private static func fold(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division)
            .first { $0.isActive && $0.frame.width > $0.frame.height }?
            .frame
    }

    /// Spreading two fingers fills the screen, cutting the picture's edges; pinching fits it.
    private func pinched(_ magnification: CGFloat) {
        if magnification > 1.15 {
            fillsScreen = true
        } else if magnification < 0.87 {
            fillsScreen = false
        }
    }
    #endif

    private static var hasNoCenterButton: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var pictureInPictureAction: (() -> Void)? {
        #if os(iOS) || os(macOS)
        pictureInPicture.isPossible ? { pictureInPicture.toggle() } : nil
        #else
        nil
        #endif
    }

    /// For a server title. On Apple TV, SharePlay starts from a title's page.
    private var playElsewhereAction: (() -> Void)? {
        #if os(tvOS)
        nil
        #else
        model.item != nil ? { showsPlayElsewhere = true } : nil
        #endif
    }

    @ViewBuilder private var statusOverlay: some View {
        if let failure = shownFailure {
            failureCard(failure)
        } else {
            switch model.status {
            case .preparing, .loading, .buffering:
                // With the controls up, the play button shows this instead (on Apple TV there is none).
                if !showsControls || Self.hasNoCenterButton {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .accessibilityLabel("Loading")
                }
            default:
                EmptyView()
            }
        }
    }

    /// Why the playback failed, while it has, and through a try again's first moment.
    private var shownFailure: String? {
        switch model.status {
        case .failed(let message): message
        case .preparing, .loading: isRetrying ? failure : nil
        default: nil
        }
    }

    private func failureCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            // The spinner takes the symbol's place, and its room, so the card keeps its size.
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                .opacity(isRetrying ? 0 : 1)
                .overlay {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
                .accessibilityHidden(true)
            Text(isRetrying ? "Trying Again…" : "Couldn't Play This").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            #if os(tvOS)
            LoadFailureActions(alignment: .center, isProminent: true, retryFocus: $retryFocused) {
                retry { await model.retry() }
            } more: {
                failureActions
            }
            .focusSection()
            #else
            LoadFailureActions(alignment: .center, isProminent: true) {
                retry { await model.retry() }
            } more: {
                failureActions
            }
            #endif
        }
        .padding(30)
        .platformGlass(in: .rect(cornerRadius: 28))
        .padding()
        .accessibilityIdentifier("player.failure")
    }

    /// Long enough for a try that fails at once to read as a try.
    private static let retryHold: Duration = .seconds(0.8)

    /// Tries to play again by `attempt`, the failure staying up meanwhile for `retryHold`, with
    /// a spinner in place of its symbol.
    private func retry(_ attempt: @escaping () async -> Void) {
        guard !isRetrying else { return }
        isRetrying = true
        announce("Trying again")
        Task { await attempt() }
        Task {
            try? await Task.sleep(for: Self.retryHold)
            isRetrying = false
        }
    }

    /// The ways on from a failure besides Try Again.
    @ViewBuilder private var failureActions: some View {
        if model.item != nil, !model.isTranscoding {
            Button("Play Through the Server") { retry { await model.retryTranscoded() } }
        }
        Button("Close", action: onClose)
    }

    @ViewBuilder private var extras: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            // In the credits the up-next card is the way past them, when there's a next episode.
            let action = shownAction(at: model.clock.time)
            let upNext: JellyfinItem? = if case .upNext(let next) = action { next } else { nil }
            let skip: MediaSegment? = if case .skip(let segment) = action { segment } else { nil }
            // Clear of the controls' bottom bar, however tall the text makes it.
            GeometryReader { geometry in
                let bottom = fold != nil ? 16 : PlayerLayout.bottomPadding(containerMaxY: geometry.frame(in: .global).maxY,
                                                                          bottomBarTop: clearsControls ? bottomBarTop : nil)
                actionView(upNext: upNext, skip: skip,
                           form: PlayerLayout.upNextForm(controlsVisible: clearsControls, isShort: controlsAreShort),
                           width: geometry.size.width)
                    .padding(.horizontal, Metrics.playerInset)
                    .padding(.bottom, bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .animation(reduceMotion ? nil : .snappy, value: upNext?.id ?? skip?.skipTitle)
            }
            // They come and go over the picture, where VoiceOver wouldn't find them in time.
            .onChange(of: skip?.skipTitle) { _, title in
                if let title { announce("\(title) available") }
            }
            .onChange(of: upNext?.id) {
                if let upNext { announce("Up next: \([upNext.episodeCode, upNext.name].compactMap(\.self).joined(separator: ", "))") }
            }
        }
    }

    /// The up-next card or the skip button, sliding in from the side and back out. `width` is the
    /// screen's, which a wide one sizes the card by.
    @ViewBuilder private func actionView(upNext: JellyfinItem?, skip: MediaSegment?, form: PlayerLayout.UpNextForm,
                                         width: CGFloat) -> some View {
        if let upNext {
            ZStack {
                switch form {
                case .card:
                    #if os(tvOS)
                    UpNextCard(model: model, episode: upNext, focus: $focus, isClickTarget: !controlsVisible)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { upNextCardTop = $0 }
                        .onDisappear { upNextCardTop = nil }
                    #else
                    UpNextCard(model: model, episode: upNext, width: PlayerLayout.upNextCardWidth(containerWidth: width))
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { upNextCardTop = $0 }
                        .onDisappear { upNextCardTop = nil }
                    #endif
                case .pill:
                    UpNextPill(model: model, episode: upNext)
                        .frame(maxWidth: width * 0.6, alignment: .trailing)
                }
            }
            .id(upNext.id)
            .motionTransition(.move(edge: .trailing).combined(with: .opacity), reduceMotion: reduceMotion)
        } else if let segment = skip, let title = segment.skipTitle {
            Button {
                model.seek(to: segment.end)
            } label: {
                Label(title, systemImage: "forward.end.fill")
            }
            .buttonStyle(.platformGlassProminent)
            .controlSize(.large)
            #if os(tvOS)
            .modifier(ClickTarget(isTarget: !controlsVisible))
            .focused($focus, equals: .action)
            #endif
            .accessibilityIdentifier("player.skip")
            .id(segment.start)
            .motionTransition(.move(edge: .trailing).combined(with: .opacity), reduceMotion: reduceMotion)
        }
    }

    #if !os(tvOS)
    /// A command from the Playback menu, or its key. The controls come up to show what it did.
    private func perform(_ command: PlayerCommand) {
        switch command {
        case .playPause:
            model.togglePlayPause()
        case .skipBack:
            model.skip(by: -PlayerModel.skipInterval)
        case .skipForward:
            model.skip(by: PlayerModel.skipInterval)
        case .nextEpisode:
            guard let next = model.nextEpisode else { return }
            Task { await model.play(next) }
        case .fullScreen:
            #if os(macOS)
            NSApplication.shared.keyWindow?.toggleFullScreen(nil)
            #else
            fillsScreen.toggle()
            #endif
        case .close:
            if panel != nil { closePanel() } else { onClose() }
            return
        }
        showControls()
    }
    #endif

    // MARK: Controls visibility

    /// `holding` keeps controls it shows up until they're hidden the same way, for an assistive
    /// technology's activation.
    private func toggleControls(holding: Bool = false) {
        if panel != nil {
            closePanel()
        } else if controlsVisible {
            hideControls()
        } else {
            showControls(holding: holding)
        }
    }

    private func closePanel() {
        panel = nil
        scheduleHide()
    }

    private func showControls(autoHide: Bool = true, holding: Bool = false) {
        if holding { holdsControls = true }
        #if os(tvOS)
        controlsCompact = false
        #endif
        controlsVisible = true
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(false)
        #endif
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hideControls() {
        hideTask?.cancel()
        guard model.isPlaying, !model.scrubbing.isActive, panel == nil, fold == nil else { return }
        controlsVisible = false
        holdsControls = false
        #if os(macOS)
        // The pointer goes with them, until it moves: over the picture only, and only with the
        // app in front, as it would vanish over another app's window too.
        if pointerIsOver, NSApp.isActive { NSCursor.setHiddenUntilMouseMoves(true) }
        #endif
    }

    /// Hides the controls in a few seconds, unless they're held or VoiceOver or Switch Control is
    /// on: those move through the controls one at a time, which takes longer.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !holdsControls, !voiceOverEnabled, !switchControlEnabled else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { hideControls() }
        }
    }
}

extension EnvironmentValues {
    /// Counts the asks to show the player's controls from outside it, as Portable TV's remote
    /// makes them; the player shows them on each.
    @Entry var playerControlsRequests = 0
}

#if os(macOS)
/// Fades the player window's close, minimize and zoom buttons out and back in. The window's
/// title bar is hidden, so they sit on the picture.
private struct WindowButtons: NSViewRepresentable {
    let areHidden: Bool

    func makeNSView(context: Context) -> ButtonsView { ButtonsView() }

    func updateNSView(_ view: ButtonsView, context: Context) {
        view.areHidden = areHidden
    }

    final class ButtonsView: NSView {
        var areHidden = false {
            didSet { if areHidden != oldValue { apply(animated: true) } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(animated: false)
        }

        private func apply(animated: Bool) {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.25 : 0
                for button in buttons { button.animator().alphaValue = areHidden ? 0 : 1 }
            }
        }
    }
}
#endif

#if os(tvOS)
/// The skip button or the up-next card's Play Now while a click on the picture takes it, with the
/// controls hidden: white, as a button with focus is, though focus stays on the picture.
private struct ClickTarget: ViewModifier {
    let isTarget: Bool

    func body(content: Content) -> some View {
        if isTarget {
            content
                .tint(.white)
                .foregroundStyle(.black)
        } else {
            content
        }
    }
}
#endif

/// A brief word over the picture, such as a move to a lower quality, below the controls' top
/// bar while they show.
private struct PlayerNotice: View {
    let text: String
    /// The bottom of the controls' top bar in global coordinates while they show.
    var controlsBottom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let clearBelow = controlsBottom.map { max(0, $0 - geometry.frame(in: .global).minY) } ?? 0
            Label(text, systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .platformGlass(in: .capsule)
                .padding(.top, clearBelow + 12)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Metrics.playerInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.notice")
    }
}

/// The card offering the next episode near the end, counting down when it plays by itself. On
/// Apple TV a click on the picture plays it, while the controls are hidden; Back hides it then.
private struct UpNextCard: View {
    let model: PlayerModel
    let episode: JellyfinItem
    #if os(tvOS)
    let focus: FocusState<PlayerFocus?>.Binding
    /// A click on the picture plays it.
    let isClickTarget: Bool
    private let layout = Layout.tv
    #else
    /// From `PlayerLayout.upNextCardWidth(containerWidth:)`.
    let width: CGFloat
    private var layout: Layout { Layout(width: width) }
    #endif
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        AdaptiveStack(spacing: layout.spacing) {
            // At the accessibility text sizes the words take the room.
            if !dynamicTypeSize.isAccessibilitySize {
                Artwork(url: session?.landscape(episode, width: layout.artworkPixels), aspectRatio: 16.0 / 9.0,
                        cornerRadius: layout.artworkRadius, placeholder: "play.rectangle")
                    .frame(width: layout.artworkWidth)
            }
            VStack(alignment: .leading, spacing: layout.lineSpacing) {
                if let countdown = model.upNextCountdown {
                    Text("Next episode in \(countdown)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                } else {
                    Text("Up Next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text([episode.episodeCode, episode.name].compactMap(\.self).joined(separator: " · "))
                    .font(layout.titleFont)
                    .lineLimit(dynamicTypeSize.lineLimit(2))
                AdaptiveStack {
                    Button("Play Now") { Task { await model.play(episode) } }
                        .buttonStyle(.platformGlassProminent)
                        #if os(tvOS)
                        .modifier(ClickTarget(isTarget: isClickTarget))
                        .focused(focus, equals: .action)
                        #endif
                        .accessibilityIdentifier("player.playNext")
                    #if os(tvOS)
                    if isClickTarget {
                        // Focus stays on the picture, where Hide can't be reached; Back hides it.
                        Text("Press Back to Hide")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Hide") { model.cancelUpNext() }
                            .buttonStyle(.platformGlass)
                            .focused(focus, equals: .hideUpNext)
                    }
                    #else
                    Button("Hide") { model.cancelUpNext() }
                        .buttonStyle(.platformGlass)
                    #endif
                }
                .controlSize(layout.buttonSize)
                #if os(tvOS)
                // Each button's words on one line: squeezed, they'd wrap a word or a letter a line.
                .lineLimit(1)
                .fixedSize()
                .padding(.top, 8)
                #endif
            }
        }
        .padding(layout.padding)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? max(640, layout.width) : layout.width, alignment: .leading)
        .platformGlass(in: .rect(cornerRadius: layout.radius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.upNext")
    }

    /// The phone's card is 440 points wide; a wider screen's is larger in proportion, its title
    /// and buttons too. Apple TV's text is about twice the size, seen from across the room, and
    /// so is its card.
    private struct Layout {
        let width: CGFloat
        let artworkWidth: CGFloat
        let artworkRadius: CGFloat
        let spacing: CGFloat
        let lineSpacing: CGFloat
        let padding: CGFloat
        let radius: CGFloat
        let buttonSize: ControlSize
        let titleFont: Font

        var artworkPixels: Int { Int(artworkWidth * 3) }

        #if os(tvOS)
        static let tv = Layout(width: 860, artworkWidth: 320, artworkRadius: 16, spacing: 28, lineSpacing: 6, padding: 24,
                               radius: 36, buttonSize: .regular, titleFont: .subheadline.weight(.semibold))
        #else
        init(width: CGFloat) {
            let isLarge = width >= 500
            self.width = width
            artworkWidth = (width * 0.34).rounded()
            artworkRadius = isLarge ? 12 : 8
            spacing = isLarge ? 18 : 14
            lineSpacing = isLarge ? 6 : 4
            padding = isLarge ? 16 : 12
            radius = isLarge ? 26 : 20
            buttonSize = isLarge ? .regular : .small
            titleFont = (isLarge ? Font.headline : .subheadline).weight(.semibold)
        }
        #endif
    }
}

/// The up-next card as a slim button just above the timeline, where the controls leave no room
/// for the card under the transport: what's next and, counting down, how soon. It plays it; the
/// card, with Hide, comes back as the controls go.
private struct UpNextPill: View {
    let model: PlayerModel
    let episode: JellyfinItem

    var body: some View {
        Button {
            Task { await model.play(episode) }
        } label: {
            Label {
                let when = Text(model.upNextCountdown.map { "Next in \($0)" } ?? "Up Next").fontWeight(.bold).monospacedDigit()
                let what = Text([episode.episodeCode, episode.name].compactMap(\.self).joined(separator: " · ")).fontWeight(.regular)
                Text("\(when)  \(what)")
            } icon: {
                Image(systemName: "play.fill")
            }
            .lineLimit(1)
        }
        .buttonStyle(.platformGlassProminent)
        .accessibilityLabel("Play Next Episode")
        .accessibilityValue([model.upNextCountdown.map { "Starts in \($0)" }, episode.episodeCode, episode.name]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("player.playNext")
    }
}

#if os(iOS) || os(macOS)
/// Picture in Picture for whichever layer the engine draws into: AVPlayer's on the native path,
/// the sample-buffer layer on the software path.
@Observable
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var isPossible = false
    private(set) var isActive = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var engine: AetherEngine?
    @ObservationIgnored private var attachedLayer: AnyObject?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?

    /// Builds the controller for the layer the engine is drawing into now.
    func attach(to engine: AetherEngine) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.engine = engine
        let controller: AVPictureInPictureController?
        if let layer = engine.nativePlayerLayer {
            guard attachedLayer !== layer else { return }
            attachedLayer = layer
            controller = AVPictureInPictureController(playerLayer: layer)
        } else if let source = engine.softwarePiPSource {
            guard attachedLayer !== source.layer else { return }
            attachedLayer = source.layer
            controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: self))
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

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = true
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = false
            self.isActive = false
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

/// The system's AirPlay and audio route button, on glass the size of the player's glass buttons
/// beside it. The system's button can't take a button style, so a glass button like those, laid
/// out and not drawn, gives the size. The system draws its icon in proportion to its own size,
/// which at 36 points matches the 22-point symbols of the buttons beside it.
struct RoutePicker: View {
    var body: some View {
        Button {} label: { Color.clear.frame(width: 22, height: 22) }
            .buttonStyle(.platformGlass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .hidden()
            .overlay {
                RoutePickerRepresentable()
                    .frame(maxWidth: 36, maxHeight: 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .platformGlass(in: .circle)
                    .accessibilityLabel("AirPlay")
            }
    }
}

#if os(iOS)
private struct RoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
private struct RoutePickerRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
#endif

#if os(iOS)
/// Turns the player the way the phone is turned, while it holds still for watching lying down.
struct RotateButton: View {
    var onUse: () -> Void = {}
    @Environment(PlayerOrientationLock.self) private var lock: PlayerOrientationLock?

    var body: some View {
        if let lock, let offer = lock.offer {
            Button {
                lock.rotate()
                onUse()
            } label: {
                Image(systemName: offer.isPortrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.platformGlass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Rotate")
            .accessibilityIdentifier("player.rotate")
        }
    }
}
#endif
