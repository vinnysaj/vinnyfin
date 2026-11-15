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
    @Environment(IncomingLinks.self) private var links
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
    /// Where each panel's button is, in global coordinates, for its panel to open above it.
    @State private var panelButtonFrames: [PlayerPanel: CGRect] = [:]
    #if !os(tvOS)
    @State private var pictureTaps = PictureTaps(mode: PlayerView.pictureTapMode)
    /// The controls as they were before the last tap on the picture that showed or hid them,
    /// for a double tap to put them back.
    @State private var controlsBeforeTap: ControlsBefore?
    /// The volume keys were pressed a moment ago, and the volume shows.
    @State private var showsVolume = false
    @State private var volumeTask: Task<Void, Never>?
    #endif
    #if os(iOS)
    /// The side of the picture a run of double taps is skipping on.
    @State private var pictureSkip: PictureSkip?
    /// How far down the picture is pulled, to close it.
    @State private var pull: CGFloat = 0
    #endif
    #if os(macOS)
    @State private var isFullScreen = false
    /// The window floats above other windows, as Playback › Float on Top has it.
    @State private var floatsOnTop = false
    #endif
    /// Where the controls' bottom bar starts, in global coordinates.
    @State private var bottomBarTop: CGFloat?
    /// Where the controls' top bar ends, in global coordinates.
    @State private var topBarBottom: CGFloat?
    /// Where the up-next card, its pill or the chip is while it shows, in global coordinates,
    /// for the subtitles and the starting title to keep clear of.
    @State private var cornerAction: CGRect?
    /// A title is starting: from asking for it until its first frame.
    @State private var isStartingTitle = true
    /// The end screen was tapped beside, for the controls, until the title plays again.
    @State private var endScreenSetAside = false
    #if os(iOS) || os(macOS)
    @State private var externalPlayback = ExternalPlayback()
    /// The AirPlay receiver that got only the sound, while that's being said.
    @State private var soundOnlyReceiver: String?
    @State private var soundOnlyTask: Task<Void, Never>?
    #endif
    #if os(macOS)
    @State private var pointerIsOver = false
    #endif
    #if os(iOS)
    /// An iPad's pointer rests on the controls' bars, which keeps them up.
    @State private var pointerIsOnControls = false
    #endif
    #if os(tvOS)
    @FocusState private var focus: PlayerFocus?
    /// Try Again over a playback that failed, which takes focus from the controls as it appears.
    @FocusState private var retryFocused: Bool
    /// The lighter stream offered while the sound plays with no picture, which takes focus from
    /// the controls as it appears.
    @FocusState private var offerFocused: Bool
    /// The controls show just the timeline, as the remote moves it while they were hidden.
    @State private var controlsCompact = false
    @State private var touchSurface = TouchSurface()
    /// The sideways swipe under way, which a circle that began as it goes back to.
    @State private var swipe = SwipeUndo()
    /// Drops a position chosen while playing that's been left alone (`StraySwipe`).
    @State private var strayTask: Task<Void, Never>?
    /// An up or down move held back while it's unclear whether the finger is starting round the
    /// ring (`VerticalMove`).
    @State private var heldMove: HeldMove?
    /// The timeline is up only because a finger rested on the remote with the controls hidden
    /// (`RemotePeek`): it goes soon after the finger lifts, unless something else used it.
    @State private var controlsByPeek = false
    /// The finger that brought the timeline up rests on still, which keeps it up.
    @State private var peekIsHeld = false
    #else
    @FocusState private var hasKeyboardFocus: Bool
    #endif
    #if os(iOS)
    @Environment(AppSettings.self) private var settings
    @State private var orientationLock = PlayerOrientationLock()
    /// The fold across the screen of an iPhone Duo standing half open, in window coordinates.
    @State private var fold: CGRect?
    /// The whole screen's size, which the episodes' sheet fills the part below the picture of.
    @State private var screenSize: CGSize = .zero
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
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
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { screenSize = $0 }
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
                        PlayerBackdrop(item: model.shownItem,
                                       coveredBelow: captionPlace.coveredBelow) {
                            coverCaption(cover)
                        }
                    }
                    .transition(.opacity)
                }
            }
            #if os(tvOS)
            if !controlsVisible, !showsEndScreen {
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
                        if direction == .up || direction == .down { moveVertically(direction, fromTimeline: false) }
                    }
                    .accessibilityLabel("Video")
                    .accessibilityHint("Shows the controls")
                    .accessibilityAction { showControls(holding: true) }
            }
            #else
            // Taps on the picture show and hide the controls, and double taps skip or go full
            // screen (`PictureTaps`); taps on a control stay with it.
            Color.clear
                .contentShape(.rect)
                .frame(height: fold?.minY)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                #if os(iOS)
                .modifier(PictureTouches(onTap: { x, width in pictureTapped(PictureTaps.zone(x: x, width: width)) },
                                         onHoldBegan: holdBegan, onHoldEnded: { model.endHoldingSpeed() },
                                         canPull: panel == nil, pull: $pull, onPulledAway: onClose, onPinch: pinched))
                #else
                .gesture(SpatialTapGesture().onEnded { _ in pictureTapped(.middle) })
                #endif
                // So VoiceOver, Voice Control ("Tap Video") and Switch Control, too, can bring back
                // controls that have faded; brought back that way, they stay.
                .accessibilityElement()
                .accessibilityLabel("Video")
                .accessibilityHint("Shows or hides the controls")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggleControls(holding: true) }
                .accessibilityIdentifier("player.picture")
            #if os(iOS)
            if let pictureSkip, let run = model.scrubbing.skipRun {
                inPictureArea {
                    SkipRipple(forward: pictureSkip.forward, seconds: run.seconds, taps: pictureSkip.taps,
                               showsTally: !showsControls)
                        .ignoresSafeArea()
                }
                .transition(.opacity)
            }
            #endif
            #endif
            #if os(visionOS)
            // The controls are in an ornament below the window (see `controlsOrnament`).
            #else
            #if os(tvOS)
            // The end screen stands in for them.
            if controlsVisible, !showsEndScreen {
                PlayerControls(model: model, fillsScreen: $fillsScreen, panel: $panel,
                               bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                               onClose: onClose, onInteraction: scheduleHide, pictureInPicture: nil, playElsewhere: nil,
                               focus: $focus, isCompact: controlsCompact,
                               onTimelineSelect: timelineClicked, onTimelineMove: timelineMoved,
                               holdsFocusOnTimeline: timelineHoldsFocus)
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
            } else if controlsVisible, !showsEndScreen {
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
                RotationLockButton(onUse: scheduleHide)
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
                                coveredBelow: PlayerLayout.coveredBelow(clearsControls ? bottomBarTop : nil, cornerAction?.minY))
                    .frame(height: fold?.minY)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
            inPictureArea { extras }
            if showsEndScreen, let item = model.item {
                inPictureArea { endScreen(item) }
                    .transition(.opacity)
            }
            // Over the controls, which stay up around it with nothing in it to act on.
            inPictureArea { statusOverlay }
            if let notice = model.notice {
                inPictureArea {
                    PlayerNotice(notice: notice, controlsBottom: controlsVisible && fold == nil && Self.controlsArePictureOverlay ? topBarBottom : nil)
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
            #if !os(tvOS)
            if let flash = playerFlash {
                inPictureArea { PlayerFlash(kind: flash, controlsBottom: clearsControls ? topBarBottom : nil) }
                    .transition(.opacity)
            }
            #endif
            #if os(iOS) || os(macOS)
            if panel == .episodes, !showsEpisodesInSheet, let item = model.item {
                episodesDrawer(item)
            }
            #endif
            #if os(iOS)
            // What the episodes' sheet is presented from: the player has a sheet of its own.
            Color.clear
                .frame(width: 0, height: 0)
                .sheet(isPresented: episodesSheet) { episodesSheetContent }
            #endif
            if panel == .quality, !PlayerPanel.quality.opensInPopover {
                placed(.quality, opensFrom: Self.qualityButtonIsAtTop ? .top : .bottom) { room in
                    QualityPanel(model: model, room: room) { closePanel() }
                }
            }
            if let panel, panel.isTrackPanel, !panel.opensInPopover {
                placed(panel, opensFrom: .bottom) { room in
                    TrackPanel(model: model, panel: panel, room: room) { closePanel() }
                }
            }
        }
        .onPreferenceChange(PanelButtonFrames.self) { panelButtonFrames = $0 }
        #if os(iOS)
        // Pulled down, the player follows the finger, shrinking as it goes, over the app it
        // leaves: the cover has no background of its own behind the picture's.
        .scaleEffect(1 - min(pull, 600) / 3000, anchor: .top)
        .offset(y: pull)
        .presentationBackground(.clear)
        .animation(.easeOut(duration: 0.2), value: pictureSkip)
        #endif
        #if !os(tvOS)
        .animation(.easeOut(duration: 0.2), value: playerFlash)
        #endif
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
        .ornament(visibility: controlsVisible && !showsEndScreen ? .visible : .hidden, attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            controlsOrnament
        }
        .preferredSurroundingsEffect(model.isPlaying && showsPicture ? .dark : nil)
        // The window's grab bar and close button go with the controls, off the picture and out
        // of the dark theater, as the system player's do.
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        // A new picture is flat until the screen showing it finds otherwise.
        .onReceive(model.engine.$currentAVPlayer.removeDuplicates { $0 === $1 }) { _ in coordinator.pictureIsStereo = false }
        .onChange(of: coordinator.screenTaps) { toggleControls() }
        #endif
        #if os(iOS)
        .animation(.snappy, value: orientationLock.isAnnouncing)
        .animation(.smooth, value: fold)
        .environment(orientationLock)
        .onHingeChange { _, context in orientationLock.hingeChanged(isHalfOpen: context.hinge?.status == .partiallyOpen) }
        .onAppear {
            orientationLock.start(landscapeTitles: settings.playsVideosInLandscape)
            if let pictureShape { orientationLock.pictureShaped(pictureShape) }
        }
        .onDisappear { orientationLock.stop() }
        .onChange(of: pictureShape) { _, shape in
            if let shape { orientationLock.pictureShaped(shape) }
        }
        // An iPad's pointer brings the controls up as it moves over the picture, and keeps them up
        // while it rests on their bars.
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let location):
                pointerIsOnControls = controlsVisible
                    && PlayerLayout.isOnBars(y: location.y, topBarBottom: topBarBottom, bottomBarTop: bottomBarTop)
                showControls(autoHide: !pointerIsOnControls)
            case .ended:
                pointerIsOnControls = false
                scheduleHide()
            }
        }
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
        .background(PlayerWindowShape(videoSize: model.videoSize, floatsOnTop: floatsOnTop,
                                      onWindow: { if let window = $0 { coordinator.playerWindow = window } }) { isFullScreen = $0 })
        .environment(\.playerIsFullScreen, isFullScreen)
        #endif
        #if os(tvOS)
        .background {
            // A timeline a resting finger brought up guards against a thumb on the surface as one
            // hidden does.
            RemoteInput(surface: touchSurface, isActive: remoteDrivesTimeline, ringArms: controlsVisible,
                        swipeThreshold: StraySwipe.threshold(controlsHidden: !controlsVisible || controlsByPeek,
                                                             isScrubbing: model.scrubbing.isActive),
                        onGesture: remote)
        }
        .onChange(of: touchSurface.reading) { _, reading in
            model.scrubbing.isOnRing = reading == .armed || reading == .turning
            settleHeldMove()
        }
        .onPlayPauseCommand {
            // Moving the timeline, Play jumps there and plays (`PlayerModel.togglePlayPause`).
            model.togglePlayPause()
            showControls()
        }
        // Leaving the timeline leaves the position chosen on it, as Back does: playback stays
        // where it is, and the controls can go.
        .onChange(of: focus) { old, new in
            guard old == .timeline, new != .timeline else { return }
            if new != nil, new != .picture { controlsByPeek = false }
            if model.scrubbing.isActive { model.cancelScrub() }
        }
        // A position chosen while paused, the playback started some other way, as the group
        // watching together can: left alone, it goes as one chosen while playing does.
        .onChange(of: model.isPlaying) { _, playing in
            if playing { dropPositionWhenLeft() }
        }
        .onExitCommand {
            if model.scrubbing.isActive {
                // Back to where playback is.
                model.cancelScrub()
                scheduleHide()
            } else if panel != nil {
                closePanel()
            } else if model.upNextCountdown != nil || model.upNextPhase(at: model.clock.time).map({ $0 != .ended }) == true {
                // The countdown stops, or the card goes, as its other button would, before the
                // controls or the player: the next Back does those.
                model.cancelUpNext()
            } else if model.showsEndScreen {
                onClose()
            } else if controlsVisible, model.isPlaying || model.status == .paused {
                // Playing or paused, Back hides the controls first, to look at the picture; the
                // next Back leaves.
                hideControls(explicit: true)
            } else {
                onClose()
            }
        }
        // Hidden, the controls leave the remote to the picture; shown, it starts on the timeline,
        // on what the card or the end screen offers, or after a failure on Try Again.
        .onChange(of: controlsVisible) { _, visible in
            if visible, case .failed = model.status {
                retryFocused = true
            } else if visible, !controlsCompact, offersAction {
                moveFocus(to: .action)
            } else {
                focus = visible ? .timeline : .picture
            }
        }
        // Asked whether anyone is still watching, or at the end, focus goes to what's offered.
        .onChange(of: model.asksStillWatching) { _, asks in
            if asks { moveFocus(to: .action) }
        }
        .onChange(of: showsEndScreen) { _, shows in
            if shows { moveFocus(to: .action) }
        }
        // Skips and scans from elsewhere, as Siri's or a TV remote's, show on the timeline too.
        .onChange(of: model.scrubbing.skipRun?.id) { _, run in
            if run != nil { revealTimeline() }
        }
        .onChange(of: model.scrubbing.isScanning) { _, scanning in
            if scanning { revealTimeline() }
        }
        // As do seeks another device or the group asked for.
        .onChange(of: model.seeksFromElsewhere) { revealTimeline() }
        #else
        .onChange(of: model.seeksFromElsewhere) { showControls() }
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
        .focusedValue(\.player, PlayerCommandTarget(model: model, fillsScreen: fillsScreen, isFullScreen: isWindowFullScreen,
                                                    floatsOnTop: isFloatingOnTop, pictureInPicture: pictureInPictureAction,
                                                    perform: perform))
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
                announce("Couldn't play this. \(message)")
                #if os(tvOS)
                // Once the card is up: focus can't go to a button that isn't there yet, and the
                // controls would keep it on the timeline.
                DispatchQueue.main.async { retryFocused = true }
                #endif
            }
            if status == .ended {
                #if os(tvOS)
                // At the end the way on is the next episode, or the end screen, rather than the
                // timeline, where a click would play the episode again.
                if offersAction { moveFocus(to: .action) }
                #endif
            } else {
                endScreenSetAside = false
            }
            #if os(iOS) || os(macOS)
            coordinator.pictureInPicture.attach(to: model)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.restoreAfterBackground() }
            // Back from the background the picture can take a while to return, and the playback
            // can be waiting on its buffer: the controls show meanwhile that it's still there.
            if model.current != nil { showControls() }
        }
        .onChange(of: model.notice) { _, notice in
            if let notice { announce(notice.text) }
        }
        .onChange(of: model.pictureOffer) { _, offer in
            guard offer != nil else { return }
            announce("The picture can't keep up. \(offer?.action ?? "")?")
            #if os(tvOS)
            // Once the card is up, as for a failure's Try Again.
            DispatchQueue.main.async { offerFocused = true }
            #endif
        }
        // Turned on mid-playback, they'd need the controls to stay.
        .onChange(of: voiceOverEnabled || switchControlEnabled) { _, assisted in
            if assisted { hideTask?.cancel() }
        }
        // Portable TV's remote skipped, paused or asked for them.
        .onChange(of: controlsRequests) { showControls() }
        // Brought up while it plays, by a tap, a click, the remote, the pointer or a key: someone
        // is watching. Those the playback brings up itself, as it starts, pauses or ends, aren't.
        .onChange(of: controlsVisible) { _, visible in
            if visible, model.isPlaying { model.noteViewerActivity() }
        }
        .animation(.easeInOut(duration: 0.3), value: showsEndScreen)
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
        .onAppear(perform: appeared)
        #if os(macOS)
        // The window's playback ends with it.
        .onDisappear { coordinator.pictureInPicture.close() }
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
        strayTask?.cancel()
        switch gesture {
        case .lift:
            swipe.lifted()
            settleHeldMove()
            if peekIsHeld {
                // The timeline the resting finger brought up goes soon (`RemotePeek`).
                peekIsHeld = false
                scheduleHide()
            }
            dropPositionWhenLeft()
            return
        case .holdEnded:
            // Let go, a scan lands where it got to, or on the chapter's start it was let go at.
            guard model.scrubbing.isScanning else { return }
            model.commitScan()
            scheduleHide()
            return
        case .rest:
            peek()
            return
        default:
            break
        }
        guard remoteDrivesTimeline else { return }
        // Moving the timeline, the remote is in use: the controls go by the usual rules.
        controlsByPeek = false
        peekIsHeld = false
        let duration = model.duration
        switch gesture {
        case .swipe(let distance, let speed):
            swipe.swiped(from: model.scrubbing.position ?? model.clock.time)
            model.scrub(by: ScrubMotion.swipe(distance, speed: speed, duration: duration))
            settleHeldMove()
        case .circle(let turn, let speed, let undoesSwipe):
            if let start = swipe.circleBegan(undoesSwipe: undoesSwipe) { model.scrubbing.position = start }
            model.scrub(by: ScrubMotion.circle(turn, speed: speed ?? 0, duration: duration))
        case .click(let forward):
            // Playing, a click skips, back with subtitles for what plays again. Paused, or moving
            // the timeline already, it steps the timeline, for a click on the timeline or Play to
            // jump there.
            let seconds = forward ? PlayerModel.skipInterval : -PlayerModel.skipInterval
            if model.scrubbing.isActive || !model.isPlaying {
                model.scrub(by: seconds)
            } else if forward {
                model.skip(by: seconds)
            } else {
                model.skipBackShowingSubtitles(by: PlayerModel.skipInterval)
            }
            dropPositionWhenLeft()
        case .holdBegan(let forward):
            model.beginScan(forward: forward)
        case .lift, .holdEnded, .rest:
            break
        }
        revealTimeline()
    }

    /// With the controls hidden, a finger resting on the remote brings up the timeline, without
    /// moving it, until a moment after it lifts, as Apple TV's player shows its controls.
    private func peek() {
        guard !controlsVisible, remoteDrivesTimeline, !showsEndScreen else { return }
        controlsByPeek = true
        peekIsHeld = true
        controlsCompact = true
        controlsVisible = true
        hideTask?.cancel()
    }

    // An up or down move command, from the picture or the timeline.

    private struct HeldMove {
        let direction: MoveCommandDirection
        let fromTimeline: Bool
    }

    /// Moves on up or down, unless the move may be the start of a circle round the ring, which the
    /// focus engine reads as a swipe up or down (`VerticalMove`): then it waits to see, or is
    /// dropped.
    private func moveVertically(_ direction: MoveCommandDirection, fromTimeline: Bool) {
        let move = HeldMove(direction: direction, fromTimeline: fromTimeline)
        heldMove = nil
        switch verticalMove(pressed: touchSurface.verticalPressCame) {
        case .go: make(move, held: false)
        case .wait: heldMove = move
        case .drop: break
        }
    }

    /// The finger on the remote may be going round the ring, or swipes the timeline: nothing but the
    /// timeline takes focus. The focus engine moves focus before the move command comes, so a
    /// circle starting at the ring's side would otherwise take focus off the timeline it's moving.
    private var timelineHoldsFocus: Bool {
        focus == .timeline && (touchSurface.reading != .none || swipe.isSwiping)
    }

    private func verticalMove(pressed: Bool) -> VerticalMove.Verdict {
        VerticalMove.verdict(ring: touchSurface.reading, isSwiping: swipe.isSwiping, pressed: pressed)
    }

    /// Makes the move held back once the finger shows it wasn't circling, or drops it once it shows
    /// it was.
    private func settleHeldMove() {
        guard let move = heldMove else { return }
        switch verticalMove(pressed: false) {
        case .go:
            heldMove = nil
            make(move, held: true)
        case .drop:
            heldMove = nil
        case .wait:
            break
        }
    }

    /// An up or down move, where it was made: from the timeline it puts focus where the move goes,
    /// wherever the focus engine took it; over the picture it brings up the controls. One `held`
    /// back goes only from where it was made.
    private func make(_ move: HeldMove, held: Bool) {
        if move.fromTimeline {
            guard !held || focus == .timeline else { return }
            moveFromTimeline(move.direction)
        } else {
            guard !controlsVisible else { return }
            showControls()
        }
    }

    /// A position chosen while playing goes, and the timeline with it, once the remote has been
    /// left alone a few seconds (`StraySwipe`): a thumb resting on the surface or picking the
    /// remote up chose it, more likely than not. Paused, it stays for a click to jump there.
    private func dropPositionWhenLeft() {
        strayTask?.cancel()
        guard model.scrubbing.isActive else { return }
        strayTask = Task {
            try? await Task.sleep(for: StraySwipe.idleLimit)
            guard !Task.isCancelled, model.scrubbing.isActive,
                  StraySwipe.dropsIdlePosition(isPlaying: model.isPlaying, isScanning: model.scrubbing.isScanning) else { return }
            model.cancelScrub()
            hideControls()
        }
    }

    /// A click with the controls hidden takes the skip button's or up-next card's action when one
    /// shows, as it can't take focus from the picture (`performShownAction`); else it plays or
    /// pauses, as the system player's does, and brings the controls up.
    private func pictureClicked() {
        if let forward = touchSurface.clickedSide(), remoteDrivesTimeline {
            remote(.click(forward: forward))
        } else if !performShownAction() {
            if model.isPlaying || model.status == .paused { model.togglePlayPause() }
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
    /// timeline, and a circle round the ring, stay on it (`moveVertically`).
    private func timelineMoved(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        moveVertically(direction, fromTimeline: true)
    }

    private func moveFromTimeline(_ direction: MoveCommandDirection) {
        controlsByPeek = false
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
        case stillWatching
        case upNext(JellyfinItem, UpNextPhase)
        case skip(MediaSegment)
        case chip(PlaybackChip)
    }

    /// What shows in the corner above the timeline, first to last: the question whether anyone is
    /// still watching, the up-next card as an episode ends, the skip button, and the chip saying
    /// the player resumed or skipped the intro.
    private func shownAction(at time: Double) -> ShownAction? {
        if model.asksStillWatching { return .stillWatching }
        if let phase = model.upNextPhase(at: time), let next = model.nextEpisode { return .upNext(next, phase) }
        if let segment = model.skippableSegment(at: time), segment.skipTitle != nil { return .skip(segment) }
        if let chip = model.chip { return .chip(chip) }
        return nil
    }

    /// A way on from the end of the title, which takes focus from the timeline as the controls come
    /// up: the up-next card, the question whether anyone is still watching, or the end screen. The
    /// skip button and the chip wait to be moved to, so a click meant for the timeline doesn't
    /// skip or start over.
    private var offersAction: Bool {
        switch shownAction(at: model.clock.time) {
        case .upNext, .stillWatching: true
        case .skip, .chip, nil: showsEndScreen
        }
    }

    /// A click on the picture with the controls hidden: the up-next card's Play Now in the credits
    /// or at the end, or the skip button. The card in the last half minute, where a click may be
    /// meant for the last scene, and the question whether anyone is still watching only bring up
    /// the controls, with their buttons ready; the chip is no click's to take.
    @discardableResult
    private func performShownAction() -> Bool {
        switch shownAction(at: model.clock.time) {
        case .upNext(_, .nearEnd), .stillWatching: showControls()
        case .upNext(let next, _): Task { await model.play(next) }
        case .skip(let segment): model.seek(to: segment.end)
        case .chip, nil: return false
        }
        return true
    }

    /// The end screen of a title with nothing after it, unless the viewer set it aside for the
    /// controls.
    private var showsEndScreen: Bool {
        model.showsEndScreen && !endScreenSetAside && showsPicture
    }

    @ViewBuilder private func endScreen(_ item: JellyfinItem) -> some View {
        #if os(tvOS)
        EndScreen(model: model, item: item, onReturn: returnToPage, focus: $focus)
        #else
        EndScreen(model: model, item: item, onReturn: returnToPage, onClose: onClose) {
            endScreenSetAside = true
            showControls(autoHide: false)
        }
        #endif
    }

    /// Closes the player on `page`'s page: the one it covers when that's the one, else the page a
    /// link to it opens.
    private func returnToPage(_ page: JellyfinItem) {
        if coordinator.pageUnderPlayer != page.id { links.open(AppLink(.open, page)) }
        onClose()
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

    /// A player that comes back for its playback, as from Picture in Picture, finds it under way:
    /// the title's picture and the fill it had carry on, and the window hands the picture back.
    private func appeared() {
        isStartingTitle = model.status == .preparing
        fillsScreen = model.engine.videoGravity == .resizeAspectFill
        #if os(iOS) || os(macOS)
        coordinator.playerAppeared()
        #endif
    }

    // MARK: Panels

    /// A panel over the controls, by the button that opened it: above a button along the bottom,
    /// growing upward over the timeline and below the top bar, or below one in the top bar, down
    /// to the bottom bar; where the band between the bars is short, as far as the screen goes.
    /// Without its button's place it keeps to the band between the bars at the trailing edge.
    ///
    /// - Parameters:
    ///   - edge: The edge it grows from as it opens: its button's.
    ///   - content: The panel, given the height there's room for.
    private func placed<Content: View>(_ panel: PlayerPanel, opensFrom edge: VerticalEdge,
                                       @ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        let clearsBars = clearsControls && !controlsAreShort
        return GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let top = clearsBars ? topBarBottom.map { max(0, $0 - frame.minY) } ?? 0 : 0
            if let button = panelButtonFrames[panel], frame.minY < button.minY, button.minY <= frame.maxY {
                if button.midY < frame.midY {
                    let below = button.maxY - frame.minY + PanelPlacement.gap
                    let bottom = clearsBars ? bottomBarTop.map { max(0, frame.maxY - $0) } ?? 0 : 0
                    content(max(0, frame.height - below - bottom - Metrics.edge))
                        .alignmentGuide(.leading) { -Self.panelLeading(width: $0.width, by: button, in: frame) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, below)
                        .padding(.bottom, bottom + Metrics.edge)
                } else {
                    let bottom = frame.maxY - button.minY + PanelPlacement.gap
                    content(max(0, frame.height - top - bottom - Metrics.edge))
                        .alignmentGuide(.leading) { -Self.panelLeading(width: $0.width, by: button, in: frame) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.top, top + Metrics.edge)
                        .padding(.bottom, bottom)
                }
            } else {
                let bottom = clearsControls ? bottomBarTop.map { max(0, frame.maxY - $0) } ?? 60 : 60
                content(max(0, frame.height - top - bottom - 2 * Metrics.edge))
                    .padding(Metrics.edge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.top, top)
                    .padding(.bottom, bottom)
            }
        }
        .motionTransition(.scale(scale: 0.94, anchor: edge == .top ? .top : .bottom).combined(with: .opacity), reduceMotion: reduceMotion)
    }

    /// The leading edge of a panel `width` wide over or under `button`, in `frame`, which both are
    /// global rectangles of.
    private nonisolated static func panelLeading(width: CGFloat, by button: CGRect, in frame: CGRect) -> CGFloat {
        PanelPlacement.leading(width: width, buttonMidX: button.midX - frame.minX, containerWidth: frame.width, margin: Metrics.edge)
    }

    // MARK: Episodes and quality

    /// The Quality button is in the controls' top bar, but on Apple TV, whose top bar takes no focus.
    private static var qualityButtonIsAtTop: Bool {
        #if os(tvOS) || os(visionOS)
        false
        #else
        true
        #endif
    }

    #if os(iOS) || os(macOS)
    private var episodesForm: EpisodesLayout.Form {
        #if os(iOS)
        EpisodesLayout.form(isCompactWidth: horizontalSizeClass == .compact, isCompactHeight: verticalSizeClass == .compact,
                            isShortBand: controlsAreShort)
        #else
        EpisodesLayout.form(isCompactWidth: false, isCompactHeight: false, isShortBand: controlsAreShort)
        #endif
    }

    private var showsEpisodesInSheet: Bool { episodesForm == .sheet }

    /// The episodes along the bottom: above the controls' bottom bar, or over it, smaller, where
    /// the band between the bars is short.
    private func episodesDrawer(_ item: JellyfinItem) -> some View {
        let form = episodesForm
        return GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let bottom = form == .rail || !clearsControls ? 0 : bottomBarTop.map { max(0, frame.maxY - $0) } ?? 0
            EpisodesPanel(model: model, playing: item, form: form, onInteraction: scheduleHide) { closePanel() }
                .padding(.horizontal, Metrics.playerInset)
                .padding(.bottom, bottom + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .motionTransition(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion)
    }
    #endif

    #if os(iOS)
    private var episodesSheet: Binding<Bool> {
        Binding {
            panel == .episodes && showsEpisodesInSheet
        } set: { shown in
            // Swiped away. Turned on its side instead, the drawer takes over.
            if !shown, panel == .episodes, showsEpisodesInSheet { closePanel() }
        }
    }

    @ViewBuilder private var episodesSheetContent: some View {
        if let item = model.item {
            EpisodesPanel(model: model, playing: item, form: .sheet) { closePanel() }
                .presentationDetents([.height(episodesSheetHeight), .large])
                // The picture above it goes on taking taps, for its transport.
                .presentationBackgroundInteraction(.enabled(upThrough: .height(episodesSheetHeight)))
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
    }

    private var episodesSheetHeight: CGFloat {
        EpisodesLayout.sheetHeight(screen: screenSize, videoSize: fillsScreen ? nil : model.videoSize)
    }
    #endif

    /// While the sound plays with no picture: a lighter way to play the title, or waiting on.
    private func pictureOfferCard(_ offer: PictureOffer) -> some View {
        StatusCard {
            pictureOffer(offer)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.pictureOffer")
    }

    private func pictureOffer(_ offer: PictureOffer) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The Picture Can't Keep Up").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("The sound is playing, but this \(Device.name) can't show this version's picture fast enough.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            AdaptiveStack {
                Button(offer.action) { model.takePictureOffer() }
                    .buttonStyle(.platformGlassProminent)
                    #if os(tvOS)
                    .focused($offerFocused)
                    #endif
                    .accessibilityIdentifier("player.pictureOffer.take")
                Button("Keep Waiting") { model.declinePictureOffer() }
                    .buttonStyle(.platformGlass)
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private enum PictureCover: Equatable {
        case starting
        case airPlay(receiver: String)
        /// The Mac's Picture in Picture window has the video. The player window goes off screen
        /// meanwhile (`PlayerCoordinator`); this is what it shows as it goes and as it comes back.
        case pictureInPicture
    }

    /// Why the title's picture stands in for the video, when it does: the title is starting, or
    /// its picture is being rebuilt after the background, which looks the same; AirPlay has the
    /// video on another screen; or on the Mac Picture in Picture has it.
    private var pictureCover: PictureCover? {
        #if os(iOS) || os(macOS)
        if externalPlayback.isActive { return .airPlay(receiver: externalPlayback.receiverName) }
        #endif
        #if os(macOS)
        if coordinator.pictureInPicture.isActive { return .pictureInPicture }
        #endif
        return isStartingTitle || model.isRestoringPicture ? .starting : nil
    }

    @ViewBuilder private func coverCaption(_ cover: PictureCover) -> some View {
        Group {
            switch cover {
            case .starting:
                ZStack {
                    if let item = model.shownItem { StartingTitle(item: item, isShort: controlsAreShort) }
                }
                .animation(.easeOut(duration: 0.3), value: model.shownItem?.id)
            case .airPlay(let receiver):
                #if os(iOS) || os(macOS)
                AirPlayCaption(receiverName: receiver)
                #endif
            case .pictureInPicture:
                Label {
                    Text("Playing in Picture in Picture")
                        .font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: "pip").font(.title)
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.pictureInPicture.cover")
            }
        }
        .padding(.trailing, captionPlace.trailingInset)
    }

    /// Where what the title's picture says sits, clear of the controls and of what the corner
    /// shows.
    private var captionPlace: (coveredBelow: CGFloat?, trailingInset: CGFloat) {
        PlayerLayout.caption(bottomBarTop: clearsControls ? bottomBarTop : nil, corner: cornerAction, isShort: controlsAreShort)
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

    /// The picture's shape as soon as it's known, for the player to turn to it: the version's, as
    /// the server lists it, until the stream's own.
    private var pictureShape: CGSize? {
        if let size = model.videoSize { return size }
        guard let video = model.current?.mediaSource?.videoStream, let width = video.width, let height = video.height else { return nil }
        return CGSize(width: width, height: height)
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

    /// The Picture in Picture button, on iPhone, iPad and the Mac.
    private var pictureInPictureAction: PictureInPictureButton? {
        #if os(iOS) || os(macOS)
        coordinator.pictureInPicture.button
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
        if let failure = model.shownFailure {
            failureCard(failure)
        } else if let offer = model.pictureOffer {
            pictureOfferCard(offer)
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

    /// Why the playback failed, while it has; through a try again's first moment
    /// (`PlayerModel.isRetrying`) it says it's trying again, with a spinner in place of its symbol.
    private func failureCard(_ message: String) -> some View {
        StatusCard {
            failure(message)
        }
        .accessibilityIdentifier("player.failure")
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            // The spinner takes the symbol's place, and its room, so the card keeps its size.
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                .opacity(model.isRetrying ? 0 : 1)
                .overlay {
                    if model.isRetrying {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
                .accessibilityHidden(true)
            Text(model.isRetrying ? "Trying Again…" : "Couldn't Play This").font(.title3.weight(.semibold))
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
    }

    /// Tries to play again by `attempt`, once at a time.
    private func retry(_ attempt: @escaping () async -> Void) {
        guard !model.isRetrying else { return }
        announce("Trying again")
        Task { await attempt() }
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
            let action = shownAction(at: model.clock.time)
            let upNext: JellyfinItem? = if case .upNext(let next, _) = action { next } else { nil }
            let skip: MediaSegment? = if case .skip(let segment) = action { segment } else { nil }
            // Clear of the controls' bottom bar, however tall the text makes it.
            GeometryReader { geometry in
                let bottom = fold != nil ? 16 : PlayerLayout.bottomPadding(containerMaxY: geometry.frame(in: .global).maxY,
                                                                          bottomBarTop: clearsControls ? bottomBarTop : nil)
                actionView(action, form: PlayerLayout.upNextForm(controlsVisible: clearsControls, isShort: controlsAreShort),
                           width: geometry.size.width)
                    #if os(tvOS)
                    // Focus stays in an open panel, as the controls' bottom bar leaves it there, and on
                    // the timeline while the remote may be moving it (`timelineHoldsFocus`).
                    .disabled(panel != nil || timelineHoldsFocus)
                    #endif
                    .padding(.horizontal, Metrics.playerInset)
                    .padding(.bottom, bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .animation(reduceMotion ? nil : .snappy, value: action.map(Self.identity))
            }
            // They come and go over the picture, where VoiceOver wouldn't find them in time.
            .onChange(of: skip?.skipTitle) { _, title in
                if let title { announce("\(title) available") }
            }
            .onChange(of: upNext?.id) {
                if let upNext { announce("Up next: \([upNext.episodeCode, upNext.name].compactMap(\.self).joined(separator: ", "))") }
            }
            .onChange(of: model.asksStillWatching) { _, asks in
                if asks { announce("Still watching? The next episode waits for an answer.") }
            }
        }
    }

    /// What the corner shows, as one value for its animation.
    private static func identity(_ action: ShownAction) -> String {
        switch action {
        case .stillWatching: "stillWatching"
        case .upNext(let next, _): "upNext \(next.id)"
        case .skip(let segment): "skip \(segment.start)"
        case .chip(let chip): "chip \(chip)"
        }
    }

    /// What the corner shows (`shownAction`), sliding in from the side and back out. `width` is
    /// the screen's, which a wide one sizes the up-next card by.
    @ViewBuilder private func actionView(_ action: ShownAction?, form: PlayerLayout.UpNextForm, width: CGFloat) -> some View {
        switch action {
        case .stillWatching:
            #if os(tvOS)
            StillWatchingCard(model: model, onStop: onClose, focus: $focus)
                .motionTransition(.move(edge: .trailing).combined(with: .opacity), reduceMotion: reduceMotion)
            #else
            StillWatchingCard(model: model, onStop: onClose)
                .motionTransition(.move(edge: .trailing).combined(with: .opacity), reduceMotion: reduceMotion)
            #endif
        case .upNext(let next, let phase):
            ZStack {
                switch form {
                case .card:
                    #if os(tvOS)
                    UpNextCard(model: model, episode: next, phase: phase, focus: $focus, controlsHidden: !controlsVisible)
                        .reportingFrame(to: $cornerAction)
                    #else
                    UpNextCard(model: model, episode: next, phase: phase, width: PlayerLayout.upNextCardWidth(containerWidth: width))
                        .reportingFrame(to: $cornerAction)
                    #endif
                case .pill:
                    UpNextPill(model: model, episode: next)
                        .frame(maxWidth: width * 0.6, alignment: .trailing)
                        .reportingFrame(to: $cornerAction)
                }
            }
            .id(next.id)
            .motionTransition(.move(edge: .trailing).combined(with: .opacity), reduceMotion: reduceMotion)
        case .skip(let segment):
            if let title = segment.skipTitle {
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
        case .chip(let chip):
            PlaybackChipButton(model: model, chip: chip)
                .controlSize(.large)
                #if os(tvOS)
                .focused($focus, equals: .action)
                #endif
                .reportingFrame(to: $cornerAction)
                .motionTransition(.move(edge: .trailing).combined(with: .opacity), reduceMotion: reduceMotion)
        case nil:
            EmptyView()
        }
    }

    #if !os(tvOS)
    /// A command from the Playback menu, or its key. The controls come up to show what it did;
    /// the volume shows by itself.
    private func perform(_ command: PlayerCommand) {
        switch command {
        case .playPause:
            model.togglePlayPause()
        case .skipBack:
            model.skip(by: -PlayerModel.skipInterval)
        case .skipForward:
            model.skip(by: PlayerModel.skipInterval)
        case .previousEpisode:
            guard model.item?.isEpisode == true else { return }
            Task { await model.playPreviousEpisode() }
        case .nextEpisode:
            guard let next = model.nextEpisode else { return }
            Task { await model.play(next) }
        case .previousChapter:
            guard !model.chapters.isEmpty else { return }
            model.seek(to: ChapterMark.previous(in: model.chapters, before: model.clock.time)?.start ?? 0)
        case .nextChapter:
            guard let next = ChapterMark.next(in: model.chapters, after: model.clock.time) else { return }
            model.seek(to: next.start)
        case .pictureInPicture:
            pictureInPictureAction?.toggle()
            return
        case .floatOnTop:
            #if os(macOS)
            floatsOnTop.toggle()
            #endif
            return
        case .episodes:
            guard model.item?.isEpisode == true, fold == nil else { return }
            panel = panel == .episodes ? nil : .episodes
        case .volumeUp, .volumeDown:
            model.changeVolume(up: command == .volumeUp)
            flashVolume()
            return
        case .mute:
            model.toggleMute()
            flashVolume()
            return
        case .subtitles:
            model.toggleSubtitles()
        case .fullScreen:
            toggleFullScreen()
        case .close:
            // A panel closes first, then full screen, then the player.
            if panel != nil {
                closePanel()
            } else if isWindowFullScreen {
                toggleFullScreen()
            } else {
                onClose()
            }
            return
        }
        showControls()
    }

    /// The Mac's window in and out of full screen; elsewhere the picture fills the screen or fits it.
    private func toggleFullScreen() {
        #if os(macOS)
        NSApplication.shared.keyWindow?.toggleFullScreen(nil)
        #else
        fillsScreen.toggle()
        #endif
    }

    /// The player's window is in full screen, which Escape leaves before it closes the player.
    private var isWindowFullScreen: Bool {
        #if os(macOS)
        isFullScreen
        #else
        false
        #endif
    }

    private var isFloatingOnTop: Bool {
        #if os(macOS)
        floatsOnTop
        #else
        false
        #endif
    }

    private func flashVolume() {
        showsVolume = true
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { showsVolume = false }
        }
    }

    /// The speed held, or the volume, over the picture for a moment.
    private var playerFlash: PlayerFlash.Kind? {
        if model.isHoldingSpeed { return .speed(PlayerModel.holdSpeed) }
        if showsVolume { return .volume(model.volume.level, isMuted: model.volume.isMuted) }
        return nil
    }

    // MARK: Taps on the picture

    private static var pictureTapMode: PictureTaps.Mode {
        #if os(iOS)
        .sideSkips
        #elseif os(macOS)
        .doubleClickFullScreen
        #else
        .toggleOnly
        #endif
    }

    /// The controls as a tap on the picture found them.
    private struct ControlsBefore {
        let visible: Bool
        let hadPanel: Bool
    }

    /// A tap on the picture in `zone` (`PictureTaps`).
    private func pictureTapped(_ zone: PictureTaps.Zone) {
        let canSkip = model.duration > 0 && controlsBeforeTap?.hadPanel != true
        switch pictureTaps.tap(at: ProcessInfo.processInfo.systemUptime, zone: zone, canSkip: canSkip) {
        case .toggleControls:
            controlsBeforeTap = ControlsBefore(visible: controlsVisible, hadPanel: panel != nil)
            toggleControls()
        case .skip(let forward, let restoresControls):
            if restoresControls { restoreControls() }
            model.skip(by: forward ? PlayerModel.skipInterval : -PlayerModel.skipInterval)
            #if os(iOS)
            let taps = pictureSkip?.forward == forward ? pictureSkip?.taps ?? 0 : 0
            pictureSkip = PictureSkip(forward: forward, taps: taps + 1)
            #endif
        case .fullScreen:
            restoreControls()
            toggleFullScreen()
        }
    }

    /// The controls back as they were before the tap that started a double tap.
    private func restoreControls() {
        guard let before = controlsBeforeTap, before.visible != controlsVisible else { return }
        if before.visible { showControls() } else { hideControls(explicit: true) }
    }
    #endif

    #if os(iOS)
    /// The side of the picture a run of double taps skips on, and how many taps it has had.
    private struct PictureSkip: Equatable {
        let forward: Bool
        let taps: Int
    }

    /// A press held on the picture plays faster until it lets go, with no panel open.
    private func holdBegan() {
        guard panel == nil else { return }
        model.beginHoldingSpeed()
    }
    #endif

    // MARK: Controls visibility

    /// `holding` keeps controls it shows up until they're hidden the same way, for an assistive
    /// technology's activation.
    private func toggleControls(holding: Bool = false) {
        if panel != nil {
            closePanel()
        } else if controlsVisible {
            hideControls(explicit: true)
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
        controlsByPeek = false
        peekIsHeld = false
        #endif
        controlsVisible = true
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(false)
        #endif
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    /// Hides the controls: by themselves only while the title plays; as the viewer asks, whenever
    /// there's a picture to look at, paused or at the end. A failure keeps them, for its way on.
    private func hideControls(explicit: Bool = false) {
        hideTask?.cancel()
        guard explicit ? hasPicture : model.isPlaying, !model.scrubbing.isActive, panel == nil, fold == nil else { return }
        controlsVisible = false
        holdsControls = false
        #if os(tvOS)
        controlsByPeek = false
        #endif
        #if os(macOS)
        // The pointer goes with them, until it moves: over the picture only, and only with the
        // app in front, as it would vanish over another app's window too.
        if pointerIsOver, NSApp.isActive { NSCursor.setHiddenUntilMouseMoves(true) }
        #endif
    }

    /// The playback has a picture up to look at without the controls: playing, paused or ended,
    /// rather than starting or failed.
    private var hasPicture: Bool {
        switch model.status {
        case .playing, .paused, .buffering, .ended: true
        case .preparing, .loading, .failed: false
        }
    }

    /// Hides the controls in a few seconds, unless they're held or VoiceOver or Switch Control is
    /// on: those move through the controls one at a time, which takes longer. On Apple TV the
    /// timeline a resting finger brought up stays while it rests, and goes sooner once it lifts,
    /// paused too, as it was hidden before. On iPad the controls stay while the pointer is on them.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !holdsControls, !voiceOverEnabled, !switchControlEnabled else { return }
        #if os(tvOS)
        guard !peekIsHeld else { return }
        let byPeek = controlsByPeek
        #else
        let byPeek = false
        #endif
        #if os(iOS)
        guard !pointerIsOnControls else { return }
        #endif
        hideTask = Task {
            try? await Task.sleep(for: byPeek ? RemotePeek.lingers : .seconds(4))
            if !Task.isCancelled { hideControls(explicit: byPeek) }
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

/// A card over the picture saying what's wrong, with the ways on. Taller than the screen, as at
/// the largest text sizes on a phone on its side or with a long message from the server, it
/// scrolls rather than cut off its buttons.
private struct StatusCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            card
            ScrollView {
                card.frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var card: some View {
        content
            .padding(30)
            .platformGlass(in: .rect(cornerRadius: 28))
            .padding()
    }
}

/// A brief word over the picture, such as a move to a lower quality, below the controls' top
/// bar while they show, with a symbol for what it's about.
private struct PlayerNotice: View {
    let notice: PlaybackNotice
    /// The bottom of the controls' top bar in global coordinates while they show.
    var controlsBottom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let clearBelow = controlsBottom.map { max(0, $0 - geometry.frame(in: .global).minY) } ?? 0
            Label(notice.text, systemImage: symbol)
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

    private var symbol: String {
        switch notice.kind {
        case .connection: "wifi.exclamationmark"
        case .remoteRequest: "iphone.radiowaves.left.and.right"
        case .info: "info.circle"
        }
    }
}

#if os(iOS) || os(macOS)
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
/// Locks the player in the shape it's in, as for watching lying down, or unlocks it to turn
/// with the phone again. Lit while the lock is what keeps the player from turning with the phone.
struct RotationLockButton: View {
    var onUse: () -> Void = {}
    @Environment(PlayerOrientationLock.self) private var lock: PlayerOrientationLock?

    var body: some View {
        if let lock, lock.isAvailable {
            Button {
                lock.toggle()
                onUse()
            } label: {
                Image(systemName: lock.isLocked ? "lock.rotation" : "lock.rotation.open")
                    .font(.headline)
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .modifier(LockStyle(isLit: lock.isTurnedAgainst))
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Rotation Lock")
            .accessibilityValue(lock.isLocked ? "On" : "Off")
            .accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("player.rotationLock")
        }
    }

    private struct LockStyle: ViewModifier {
        let isLit: Bool

        func body(content: Content) -> some View {
            if isLit {
                content.buttonStyle(.platformGlassProminent)
            } else {
                content.buttonStyle(.platformGlass)
            }
        }
    }
}
#endif

private extension View {
    /// Keeps `frame` at where this view is, in global coordinates, while it shows.
    func reportingFrame(to frame: Binding<CGRect?>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.wrappedValue = $0 }
            .onDisappear { frame.wrappedValue = nil }
    }
}
