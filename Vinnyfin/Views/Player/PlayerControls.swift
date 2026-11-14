import AetherEngine
#if os(macOS)
import AppKit
#endif
import Nuke
import OSLog
import SwiftUI

#if os(tvOS)
/// What has the remote's focus in the player.
enum PlayerFocus: Hashable {
    /// The picture, while the controls are hidden.
    case picture
    case timeline, playPause, next
    case panel(PlayerPanel)
    /// The skip button, or the up-next card's Play Now.
    case action
    case hideUpNext
}
#endif

/// The player's controls over the picture: close and title along the top, transport in the
/// middle, the timeline and track menus along the bottom. Below the fold of an iPhone Duo
/// standing half open they sit under the picture instead, with the show's episodes, and on
/// Vision Pro on a pane of glass below the window, with the transport in the bottom row. On Apple
/// TV the timeline can show by itself, as the remote moves it with the controls hidden.
struct PlayerControls: View {
    let model: PlayerModel
    @Binding var fillsScreen: Bool
    @Binding var panel: PlayerPanel?
    /// Where the timeline and buttons start, in global coordinates, so subtitles can stay above them.
    @Binding var bottomBarTop: CGFloat?
    /// Where the title and its buttons end, in global coordinates, so notices can stay below them.
    @Binding var topBarBottom: CGFloat?
    let onClose: () -> Void
    /// Called on every use, so the controls stay up while they're being used.
    let onInteraction: () -> Void
    /// Picture in Picture's button; nil where the player has none.
    let pictureInPicture: PictureInPictureButton?
    /// Opens Play On and SharePlay; nil when the playback is only this device's, or on Apple TV.
    let playElsewhere: (() -> Void)?
    var isBelowFold = false
    #if os(tvOS)
    /// The player's focus, which the remote moves between the controls. Moving counts as using
    /// them, so they stay up.
    let focus: FocusState<PlayerFocus?>.Binding
    /// Just the timeline, without the title and buttons.
    var isCompact = false
    /// A click on the timeline.
    let onTimelineSelect: () -> Void
    /// A swipe or an arrow up or down from the timeline; sideways is the remote's own (`RemoteInput`).
    let onTimelineMove: (MoveCommandDirection) -> Void
    #endif
    @Environment(SharePlay.self) private var sharePlay
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    #if !os(tvOS)
    /// The skips back and forward so far, each of which turns its button's arrow.
    @State private var backSkips = 0
    @State private var forwardSkips = 0
    #endif
    #if os(macOS)
    @Environment(\.playerIsFullScreen) private var isFullScreen
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if isBelowFold { belowFold } else { overPicture }
            #elseif os(visionOS)
            underWindow
            #else
            overPicture
            #endif
        }
        .foregroundStyle(.white)
        // A playback that failed has nothing left to choose among.
        .onChange(of: isFailed) { _, failed in
            if failed { panel = nil }
        }
        #if os(tvOS)
        .defaultFocus(focus, .timeline)
        .onChange(of: focus.wrappedValue) { onInteraction() }
        // Back to the button that opened a panel once it closes; from a tab below the buttons, to them.
        .onChange(of: panel) { closed, opened in
            if opened == nil, let closed { focus.wrappedValue = closed.isTab ? .playPause : .panel(closed) }
        }
        .animation(.easeInOut(duration: 0.25), value: isCompact)
        #else
        .onChange(of: model.scrubbing.skipRun) { _, run in
            guard let run else { return }
            if run.seconds < 0 { backSkips += 1 } else { forwardSkips += 1 }
        }
        #endif
    }

    /// Only the top bar stays, its Close and AirPlay, over a failure's own way on, through a try
    /// again's first moment too, while the failure stays up (`PlayerModel.shownFailure`).
    private var isFailed: Bool {
        model.shownFailure != nil
    }

    /// While the timeline moves in a short window, the transport makes way for its preview.
    private var hidesTransport: Bool {
        #if os(iOS)
        verticalSizeClass == .compact && model.scrubbing.isActive
        #else
        false
        #endif
    }

    /// The title and buttons are hidden, leaving the timeline.
    private var showsOnlyTimeline: Bool {
        #if os(tvOS)
        isCompact
        #else
        false
        #endif
    }

    private var overPicture: some View {
        ZStack {
            // Dark enough behind the timeline to read it over a bright picture.
            LinearGradient(stops: [
                .init(color: .black.opacity(showsOnlyTimeline ? 0 : 0.7), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(isFailed ? 0 : 0.6), location: 0.78),
                .init(color: .black.opacity(isFailed ? 0 : 0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                    .opacity(showsOnlyTimeline ? 0 : 1)
                    .accessibilityHidden(showsOnlyTimeline)
                    #if os(macOS)
                    // The window's own buttons keep the corner, beside the bar.
                    .containerCornerOffset(.leading, sizeToFit: true)
                    #endif
                Spacer()
                if !isFailed {
                    #if !os(tvOS)
                    transport
                        .opacity(hidesTransport ? 0 : 1)
                        .allowsHitTesting(!hidesTransport)
                        .accessibilityHidden(hidesTransport)
                    Spacer()
                    #endif
                    bottomBar
                    #if os(tvOS)
                    if !showsOnlyTimeline {
                        PlayerTabs(model: model, panel: $panel, focus: focus, onInteraction: onInteraction)
                            .padding(.top, 20)
                    }
                    #endif
                }
            }
            .padding(.horizontal, Metrics.playerInset)
            .padding(.vertical, 12)
            // Taller than the window, it runs off the bottom rather than taking Close off the top.
            .frame(maxHeight: .infinity, alignment: .top)
            #if os(macOS)
            // Up in the band the hidden title bar leaves, as the window's buttons are.
            .ignoresSafeArea(.container, edges: .top)
            #endif
        }
        .animation(.easeInOut(duration: 0.2), value: hidesTransport)
    }

    #if os(iOS)
    private var belowFold: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                topBar
                if !isFailed {
                    bottomBar
                    transport
                }
            }
            .padding(.horizontal, Metrics.playerInset)
            if let item = model.item, item.isEpisode {
                EpisodeStrip(model: model, playing: item, onInteraction: onInteraction)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
    }
    #endif

    #if os(visionOS)
    private var underWindow: some View {
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                topBar
                if !isFailed { bottomBar }
            }
            .padding(.horizontal, 28)
            if let item = model.item, item.isEpisode {
                EpisodeStrip(model: model, playing: item, onInteraction: onInteraction)
            }
        }
        .padding(.vertical, 22)
        .frame(width: 920)
        .glassBackgroundEffect(in: .rect(cornerRadius: 40))
    }
    #endif

    // MARK: Top

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                #if !os(tvOS)
                closeButton
                #endif
                if !isTitleOwnRow { titleBlock.padding(.top, 6) }
                Spacer()
                HStack(alignment: .top, spacing: 14) {
                    #if os(tvOS)
                    FormatBadge(model: model).padding(.top, 6)
                    #else
                    if !isTitleOwnRow { qualityButton }
                    #endif
                    if let playElsewhere {
                        Button {
                            playElsewhere()
                            onInteraction()
                        } label: {
                            symbol(PlayElsewhereSheet.symbol(sharePlay))
                        }
                        .buttonStyle(.platformGlass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .accessibilityLabel(PlayElsewhereSheet.title)
                        .accessibilityShowsLargeContentViewer()
                        .accessibilityIdentifier("player.playElsewhere")
                    }
                    #if os(iOS) || os(macOS)
                    RoutePicker()
                    if let pictureInPicture {
                        // Always there, so it's found where it was, and dimmed while the window can't start.
                        Button {
                            pictureInPicture.toggle()
                            onInteraction()
                        } label: {
                            symbol(pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                        }
                        .buttonStyle(.platformGlass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
                        .accessibilityLabel(pictureInPicture.isActive ? "Exit Picture in Picture" : "Picture in Picture")
                        .accessibilityShowsLargeContentViewer()
                        .accessibilityIdentifier("player.pictureInPicture")
                    }
                    #endif
                    #if os(iOS)
                    // Last, where it shows by itself as the phone turns against it.
                    RotationLockButton(onUse: onInteraction)
                    #endif
                }
                .dynamicTypeSize(...Self.largestControlSize)
            }
            if isTitleOwnRow {
                #if os(tvOS)
                titleBlock
                #else
                // Opposite the title, where a phone held upright has room its row of buttons hasn't.
                HStack(alignment: .top, spacing: 14) {
                    titleBlock
                    Spacer(minLength: 0)
                    qualityButton
                        .dynamicTypeSize(...Self.largestControlSize)
                }
                #endif
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
    }

    #if !os(tvOS)
    /// The way into the Quality panel, saying what plays.
    private var qualityButton: some View {
        FormatBadge(model: model) {
            panel = panel == .quality ? nil : .quality
            onInteraction()
        }
    }
    #endif

    /// Like the system player's, the buttons keep their size past the default text size, where a
    /// row of them would run off the screen; the Large Content Viewer shows each one large.
    private static let largestControlSize = DynamicTypeSize.large

    /// The title gets a row of its own, under the buttons, rather than a word or two between them:
    /// on a phone held upright, and at the accessibility sizes, but in a short window, where a row
    /// of its own would push the controls off the screen.
    private var isTitleOwnRow: Bool {
        #if os(iOS)
        if verticalSizeClass == .compact { return false }
        if horizontalSizeClass == .compact { return true }
        #endif
        return dynamicTypeSize.isAccessibilitySize
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title).font(.headline).lineLimit(dynamicTypeSize.lineLimit(isTitleOwnRow ? 2 : 1))
                .accessibilityAddTraits(.isHeader)
                .accessibilityShowsLargeContentViewer()
            if let subtitle = model.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(1))
                    .accessibilityShowsLargeContentViewer()
            }
        }
        .dynamicTypeSize(...Self.largestTextSize(compactHeight: isCompactHeight))
    }

    private var isCompactHeight: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    /// In a short window the title and times grow no larger than the first accessibility size,
    /// which leaves the controls room; the Large Content Viewer shows them larger.
    static func largestTextSize(compactHeight: Bool) -> DynamicTypeSize {
        compactHeight ? .accessibility1 : .accessibility5
    }

    #if !os(tvOS)
    private var closeButton: some View {
        Button(action: onClose) {
            symbol("xmark")
        }
        .buttonStyle(.platformGlass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("Close")
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("player.close")
        .dynamicTypeSize(...Self.largestControlSize)
    }
    #endif

    // MARK: Middle

    #if !os(tvOS)
    private var transport: some View {
        // Smaller below the fold, where it shares the half screen with the episodes, and in
        // Vision Pro's bar, where it shares a row with the other buttons.
        #if os(visionOS)
        let scale: CGFloat = 0.6
        #else
        let scale: CGFloat = isBelowFold ? 0.75 : 1
        #endif
        return HStack(spacing: 44 * scale) {
            transportButton("gobackward.10", label: "Back 10 Seconds", size: 30 * scale,
                            turn: .rotate.counterClockwise.byLayer, turns: backSkips) {
                model.skip(by: -PlayerModel.skipInterval)
            }
            .overlay(alignment: .top) { skipTally(back: true) }
            transportButton(playPauseSymbol, label: playPauseLabel, size: 44 * scale, showsProgress: isWaiting) {
                model.togglePlayPause()
            }
            .accessibilityIdentifier("player.playPause")
            transportButton("goforward.10", label: "Forward 10 Seconds", size: 30 * scale,
                            turn: .rotate.clockwise.byLayer, turns: forwardSkips) {
                model.skip(by: PlayerModel.skipInterval)
            }
            .overlay(alignment: .top) { skipTally(back: false) }
        }
        .animation(.snappy, value: model.scrubbing.skipRun)
    }

    /// `turns` counts the presses that turned the symbol by `turn`, once each.
    private func transportButton(_ symbol: String, label: String, size: CGFloat, showsProgress: Bool = false,
                                 turn: RotateSymbolEffect = .rotate, turns: Int = 0,
                                 action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            ZStack {
                if showsProgress {
                    ProgressView().controlSize(.large).tint(.white)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(turn, options: .speed(2), value: turns)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(width: size * 1.6, height: size * 1.6)
            // A pause while the spinner shows comes up as the play symbol, plainly.
            .animation(.easeOut(duration: 0.2), value: showsProgress)
        }
        .buttonStyle(.platformGlass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer()
    }

    /// The run of skips, over the button that took it: "+30". On Vision Pro the timeline is
    /// there instead.
    @ViewBuilder private func skipTally(back: Bool) -> some View {
        #if !os(visionOS)
        if let run = model.scrubbing.skipRun, (run.seconds < 0) == back {
            SkipTally(seconds: run.seconds)
                .fixedSize()
                // Standing on the button's top edge, clear of it.
                .frame(height: 0, alignment: .bottom)
                .offset(y: -10)
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
        }
        #endif
    }
    #endif

    /// Loading or refilling the buffer: the play button turns into the spinner.
    private var isWaiting: Bool {
        switch model.status {
        case .preparing, .loading, .buffering: true
        default: false
        }
    }

    /// A playback starting or refilling is on its way to playing, so the button offers to pause it,
    /// as it does while it plays, rather than to play what's already coming.
    private var playPauseLabel: String {
        switch model.status {
        case .ended: model.nextEpisode != nil ? "Next Episode" : "Play Again"
        default: model.status.isUnderway ? "Pause" : "Play"
        }
    }

    private var playPauseSymbol: String {
        switch model.status {
        case .ended: model.nextEpisode != nil ? "forward.end.fill" : "arrow.counterclockwise"
        default: model.status.isUnderway ? "pause.fill" : "play.fill"
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 10) {
            #if os(tvOS)
            Scrubber(model: model, onInteraction: onInteraction, isFocused: focus.wrappedValue == .timeline,
                     onSelect: onTimelineSelect, onMove: onTimelineMove)
                .focused(focus, equals: .timeline)
            #else
            Scrubber(model: model, onInteraction: onInteraction)
            #endif
            HStack(spacing: Self.buttonSpacing) {
                #if os(tvOS)
                Button {
                    model.togglePlayPause()
                    onInteraction()
                } label: {
                    symbol(playPauseSymbol)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.platformGlass)
                .accessibilityLabel(playPauseLabel)
                .focused(focus, equals: .playPause)
                #endif
                trackMenus
                #if os(tvOS)
                if !model.qualityOptions.isEmpty {
                    panelButton(.quality, identifier: "player.quality", text: model.qualityLabel,
                                value: model.qualityStatus?.summary)
                }
                #endif
                Spacer()
                episodeButtons
                #if os(iOS)
                Button {
                    fillsScreen.toggle()
                    onInteraction()
                } label: {
                    symbol(fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.platformGlass)
                .accessibilityLabel(fillsScreen ? "Fit to Screen" : "Fill Screen")
                .accessibilityShowsLargeContentViewer()
                #elseif os(macOS)
                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                    onInteraction()
                } label: {
                    symbol(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.platformGlass)
                .accessibilityLabel(isFullScreen ? "Exit Full Screen" : "Full Screen")
                .help(isFullScreen ? "Exit Full Screen" : "Full Screen")
                #endif
                #if os(visionOS)
                CinemaButton(onUse: onInteraction)
                #endif
            }
            // Each a circle of glass, like the buttons along the top.
            .buttonBorderShape(.circle)
            .controlSize(controlSize)
            .dynamicTypeSize(...Self.largestControlSize)
            // Hidden, they stay focusable: focus leaves the timeline only as `onTimelineMove`
            // sends it, which shows them first. Disabled, they couldn't take it as they reappear.
            .opacity(showsOnlyTimeline ? 0 : 1)
            .accessibilityHidden(showsOnlyTimeline)
            #if os(visionOS)
            // In the middle of the row, whatever is at its ends.
            .overlay { transport.controlSize(controlSize) }
            #endif
        }
        #if os(tvOS)
        // Focus stays in an open panel: nothing here can take it until the panel closes.
        .disabled(panel != nil)
        #endif
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomBarTop = $0 }
    }

    private var controlSize: ControlSize {
        #if os(tvOS)
        .regular
        #else
        .large
        #endif
    }

    /// A round glass button's symbol, in a square the same for every symbol, so the circles match.
    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.headline)
            .frame(width: Self.symbolSide, height: Self.symbolSide)
    }

    private static var symbolSide: CGFloat {
        #if os(tvOS)
        38
        #else
        22
        #endif
    }

    private static var buttonSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        12
        #endif
    }

    /// The Episodes panel, which has Previous and Next in it, for an episode on iPhone, iPad and
    /// the Mac. Elsewhere Next, and on Apple TV Previous too: below the fold and on Vision Pro the
    /// episodes are on screen already, and Apple TV has them a swipe down from these buttons.
    @ViewBuilder private var episodeButtons: some View {
        #if os(iOS) || os(macOS)
        if !isBelowFold, let item = model.item, item.isEpisode, item.seriesId != nil {
            panelButton(.episodes, identifier: "player.episodes", value: item.episodeCode)
        } else {
            nextButton
        }
        #else
        #if os(tvOS)
        if let item = model.item, item.isEpisode, item.seriesId != nil {
            Button {
                Task { await model.playPreviousEpisode() }
                onInteraction()
            } label: {
                symbol("backward.end.fill")
            }
            .buttonStyle(.platformGlass)
            .accessibilityLabel("Previous Episode")
            .accessibilityIdentifier("player.previous")
        }
        #endif
        nextButton
        #endif
    }

    @ViewBuilder private var nextButton: some View {
        if let next = model.nextEpisode {
            Button {
                Task { await model.play(next) }
            } label: {
                symbol("forward.end.fill")
            }
            .buttonStyle(.platformGlass)
            .accessibilityLabel("Next Episode")
            .accessibilityHint(next.name)
            .accessibilityShowsLargeContentViewer()
            #if os(tvOS)
            .focused(focus, equals: .next)
            #endif
        }
    }

    @ViewBuilder private var trackMenus: some View {
        // Filled while subtitles show; VoiceOver hears which, and the audio when there's a choice.
        let subtitle = model.subtitleOptions.first { $0.id == model.selectedSubtitle }?.title
        let audio = model.audioOptions.count > 1 ? model.audioOptions.first { $0.id == model.selectedAudio }?.title : nil
        panelButton(.audioAndSubtitles, identifier: "player.subtitles", filled: subtitle != nil,
                    value: [audio, "Subtitles \(subtitle ?? "Off")"].compactMap(\.self).joined(separator: ", "))
        // Away from 1×, the button reads the speed in place of its symbol.
        panelButton(.speed, identifier: "player.speed", text: model.rate == 1 ? nil : PlaybackSpeed.label(model.rate),
                    value: PlaybackSpeed.name(model.rate))
        if !model.chapters.isEmpty {
            panelButton(.chapters, identifier: "player.chapters",
                        value: ChapterMark.current(in: model.chapters, at: model.clock.time)?.name)
        }
    }

    /// `value` is what's chosen, which VoiceOver says after the button's name. With `text` the
    /// button shows it in a capsule instead of the panel's symbol.
    private func panelButton(_ kind: PlayerPanel, identifier: String, filled: Bool = false, text: String? = nil,
                             value: String?) -> some View {
        Button {
            panel = panel == kind ? nil : kind
            onInteraction()
        } label: {
            if let text {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: Self.symbolSide, minHeight: Self.symbolSide)
            } else {
                symbol(filled ? kind.symbol + ".fill" : kind.symbol)
            }
        }
        .buttonStyle(.platformGlass)
        .buttonBorderShape(text == nil ? .circle : .capsule)
        .accessibilityLabel(kind.title)
        .accessibilityValue(value ?? "")
        .accessibilityShowsLargeContentViewer()
        #if os(tvOS)
        .focused(focus, equals: .panel(kind))
        #endif
        .accessibilityIdentifier(identifier)
        // For the panel to open above it.
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelButtonFrames.self, value: [kind: geometry.frame(in: .global)])
            }
        }
    }
}

/// What's on screen when it's worth saying: a speed other than 1×, 3D, Dolby Vision or HDR, or
/// that the server is transcoding. With `action`, a button that opens the Quality panel, there
/// for every stream, which says the stream's picture size too.
private struct FormatBadge: View {
    let model: PlayerModel
    var action: (() -> Void)?
    #if os(visionOS)
    @Environment(PlayerCoordinator.self) private var coordinator
    #endif

    var body: some View {
        if let action, !model.qualityOptions.isEmpty || text != nil {
            Button(action: action) {
                // Whole, never cut short: where the bar has no room for all of it, the picture
                // size alone, and then the panel's symbol.
                ViewThatFits(in: .horizontal) {
                    if let text { Text(text).fixedSize() }
                    if let size = model.qualityLabel, size != text { Text(size).fixedSize() }
                    Image(systemName: PlayerPanel.quality.symbol)
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 22)
            }
            .buttonStyle(.platformGlass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityLabel(PlayerPanel.quality.title)
            .accessibilityValue(model.qualityStatus?.summary ?? text ?? "")
            .accessibilityShowsLargeContentViewer()
            #if os(macOS)
            .help(model.qualityStatus?.summary ?? PlayerPanel.quality.title)
            #endif
            .accessibilityIdentifier("player.quality")
            // For the panel to open below it.
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: PanelButtonFrames.self, value: [.quality: geometry.frame(in: .global)])
                }
            }
        } else if let text {
            Text(text)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .platformGlass(in: .capsule)
                .accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("player.format")
        }
    }

    private var text: String? {
        var parts: [String] = []
        if model.rate != 1 { parts.append(PlaybackSpeed.label(model.rate)) }
        #if os(visionOS)
        if coordinator.pictureIsStereo { parts.append("3D") }
        #endif
        // As the way into the Quality panel; on Apple TV that's the bottom row's, which says it.
        if action != nil, model.current?.isStream == true, let size = model.qualityLabel { parts.append(size) }
        switch model.videoFormat {
        case .dolbyVision: parts.append("Dolby Vision")
        case .hdr10: parts.append("HDR10")
        case .hdr10Plus: parts.append("HDR10+")
        case .hlg: parts.append("HLG")
        case .sdr: break
        }
        if model.isTranscoding { parts.append("Transcoding") }
        if model.current?.isDownload == true { parts.append("Downloaded") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The timeline: how far along, how much is buffered, where chapters start, and a handle to drag.
/// On Apple TV the remote moves it instead (see `RemoteInput`), and a click jumps there. While it
/// moves, a preview over it shows the picture there, when the server made scrub previews, and the
/// chapter; on Apple TV, skips show their sum over the playhead.
struct Scrubber: View {
    let model: PlayerModel
    let onInteraction: () -> Void
    #if os(tvOS)
    let isFocused: Bool
    let onSelect: () -> Void
    /// Its move handler takes every direction, so focus moves on from it only through this.
    let onMove: (MoveCommandDirection) -> Void
    #endif
    #if os(iOS) || os(visionOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var body: some View {
        @Bindable var scrubbing = model.scrubbing
        let duration = max(model.duration, 1)
        let position = scrubbing.position
        let time = position ?? model.clock.time
        VStack(spacing: 6) {
            TimelineBar(time: model.clock.time, buffered: model.clock.buffered, duration: duration, color: .white,
                        height: barHeight, marks: model.chapters.map(\.start), showsHead: showsHead,
                        position: $scrubbing.position, onSeek: nil)
                .overlay { overBar(position: position, duration: duration) }
            #if os(visionOS)
            // Tall enough to look at and pinch, and lit under the eyes as a slider is.
            .frame(height: 44)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
            #else
            .frame(height: 24)
            #endif
            timeRow(time: time, duration: duration)
        }
        #if !os(tvOS)
        // The bar and its times take the drag together, a target a finger finds though the bar is
        // drawn thin. The position holds at chapters' starts on the way.
        .timelineDragging(duration: duration, time: model.clock.time, position: $scrubbing.position,
                          rate: $scrubbing.dragRate, snapPoints: model.chapters.map(\.start), onDrag: onInteraction) {
            model.seek(to: $0)
        }
        .sensoryFeedback(Self.landmarkFeedback,
                         trigger: ScrubLandmark.at(position, duration: duration, chapters: model.chapters)) { old, new in
            ScrubLandmark.ticks(from: old, to: new)
        }
        #endif
        #if os(tvOS)
        .padding(.vertical, 8)
        .focusable()
        .onMoveCommand(perform: onMove)
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: 0.2), value: scrubbing.skipRun?.id)
        .animation(.easeOut(duration: 0.15), value: position == nil)
        #endif
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(spokenPosition(time, of: duration))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.skip(by: PlayerModel.skipInterval)
            case .decrement: model.skip(by: -PlayerModel.skipInterval)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player.timeline")
    }

    /// Elapsed and remaining time, and on a big screen when the title ends at its speed.
    private func timeRow(time: Double, duration: Double) -> some View {
        HStack {
            Text(Self.format(time))
            Spacer()
            Text(TimeLabel.remaining(duration - time))
        }
        .overlay {
            if showsEndTime, model.duration > 0 {
                // Each minute too, as a pause pushes the end on.
                TimelineView(.everyMinute) { _ in
                    let end = TimeLabel.end(after: duration - time, rate: model.rate, from: .now)
                    Text("Ends \(end, format: .dateTime.hour().minute())")
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        // Brighter than secondary, to read over a bright picture.
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .dynamicTypeSize(...PlayerControls.largestTextSize(compactHeight: isCompactHeight))
        .accessibilityShowsLargeContentViewer()
    }

    /// Where there's width to spare: Apple TV, the Mac, and an iPad's or Vision Pro's regular width.
    private var showsEndTime: Bool {
        #if os(iOS) || os(visionOS)
        horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    private var isCompactHeight: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    /// Over the bar: the preview while the timeline moves, and on Apple TV the run of skips.
    private func overBar(position: Double?, duration: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // Its bottom clear of the bar, its own height rather than the bar's.
            let above = -(geometry.size.height + barHeight) / 2 - 8
            if let position {
                let center = width * min(1, max(0, position / duration))
                ScrubPreview(model: model, time: position)
                    .offset(y: above)
                    // Centered over the handle, kept within the timeline, however wide its words make it.
                    .alignmentGuide(.leading) { -min(max(0, center - $0.width / 2), max(0, width - $0.width)) }
                    .frame(width: width, height: geometry.size.height, alignment: .bottomLeading)
                    .transition(.opacity)
            }
            #if os(tvOS)
            if position == nil, let run = model.scrubbing.skipRun {
                let center = width * min(1, max(0, model.clock.time / duration))
                SkipTally(seconds: run.seconds)
                    .fixedSize()
                    .offset(x: min(max(center, SkipTally.halfWidth), max(SkipTally.halfWidth, width - SkipTally.halfWidth)) - width / 2,
                            y: above)
                    .frame(width: width, height: geometry.size.height, alignment: .bottom)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
            #endif
        }
        .allowsHitTesting(false)
    }

    /// Where it is, with the chapter when there are chapters.
    private func spokenPosition(_ time: Double, of duration: Double) -> String {
        let position = SpokenTime.position(time, of: duration)
        guard let chapter = ChapterMark.current(in: model.chapters, at: time) else { return position }
        return "\(position), \(chapter.name)"
    }

    private var barHeight: CGFloat {
        #if os(tvOS)
        isFocused || model.scrubbing.isActive ? 12 : 8
        #else
        model.scrubbing.isActive ? 9 : 5
        #endif
    }

    /// A playhead while the timeline moves, with a mark where playback is; on Apple TV also
    /// while it has focus, where the remote would move it from.
    private var showsHead: Bool {
        #if os(tvOS)
        isFocused || model.scrubbing.isActive
        #else
        model.scrubbing.isActive
        #endif
    }

    private static var landmarkFeedback: SensoryFeedback {
        #if os(macOS)
        .alignment
        #else
        .selection
        #endif
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// How the player writes times: along the timeline, and over its preview as the timeline moves.
enum TimeLabel {
    /// Time left, after a minus sign rather than a hyphen: "−1:05:00".
    static func remaining(_ seconds: Double) -> String {
        "\u{2212}" + Scrubber.format(max(0, seconds))
    }

    /// "+2:15" ahead of where playback is, "−0:40" behind it.
    static func distance(_ seconds: Double) -> String {
        (seconds < 0 ? "\u{2212}" : "+") + Scrubber.format(abs(seconds))
    }

    /// A held direction's scanning speed, either way: "128×".
    static func scanSpeed(_ secondsPerSecond: Double) -> String {
        "\(Int(abs(secondsPerSecond).rounded()))×"
    }

    /// The fastest scanning speed for a title of `duration`, whose width every speed takes.
    static func widestScanSpeed(duration: Double) -> String {
        scanSpeed(ScrubMotion.scanLevels(duration: duration).max() ?? 0)
    }

    /// What the timeline says while a finger places it finely: nil at full speed.
    static func dragRate(_ rate: Double) -> String? {
        switch rate {
        case ..<0.5: "Fine Scrubbing"
        case ..<1: "Half-Speed Scrubbing"
        default: nil
        }
    }

    /// When a title with `seconds` left ends, played from `now` at `rate`.
    static func end(after seconds: Double, rate: Float, from now: Date) -> Date {
        now.addingTimeInterval(max(0, seconds) / Double(rate > 0 ? rate : 1))
    }
}

/// Over the timeline while it moves: the picture at that point, when the server made scrub
/// previews, with the chapter, the time, and how far that is from where playback is. On Apple
/// TV, also the speed of a held side scanning; on a touchscreen, how finely a finger slid up
/// from the bar is placing it.
private struct ScrubPreview: View {
    let model: PlayerModel
    let time: Double
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let chapter = ChapterMark.current(in: model.chapters, at: time)
        let thumbnailWidth = Self.thumbnailWidth(of: model.trickplay, scale: displayScale)
        VStack(spacing: Self.spacing) {
            if let tiles = model.trickplay {
                TrickplayThumbnail(tiles: tiles, time: time)
                    .frame(width: thumbnailWidth,
                           height: thumbnailWidth * CGFloat(tiles.info.height) / CGFloat(max(1, tiles.info.width)))
                    .clipShape(.rect(cornerRadius: Self.thumbnailRadius))
            }
            if let chapter {
                Text(chapter.name).font(.caption.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, Self.spacing)
            }
            HStack(spacing: Self.captionSpacing) {
                #if os(tvOS)
                if let speed = model.scrubbing.scanSpeed {
                    scanSpeed(speed)
                }
                #endif
                Text(Scrubber.format(time)).font(.caption.weight(.semibold))
                Text(TimeLabel.distance(time - model.clock.time)).font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            // Whole at any length: hours, a long way off, the fastest speed.
            .fixedSize()
            // Clear of the card's rounded corners when it's wider than the thumbnail.
            .padding(.horizontal, Self.spacing)
            if let rate = TimeLabel.dragRate(model.scrubbing.dragRate) {
                Text(rate)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Self.spacing)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.scrubbing.dragRate)
        .padding(model.trickplay == nil ? Self.spacing * 2 : Self.spacing)
        .frame(minWidth: thumbnailWidth + 2 * Self.spacing)
        // Its own height, not the timeline's it's laid over.
        .fixedSize()
        .platformGlass(in: .rect(cornerRadius: Self.thumbnailRadius + Self.spacing))
        .accessibilityHidden(true)
    }

    #if os(tvOS)
    /// "▶▶ 24×", as wide as the fastest speed, so the time beside it holds still as it speeds up.
    private func scanSpeed(_ speed: Double) -> some View {
        let glyph = Image(systemName: speed < 0 ? "backward.fill" : "forward.fill")
        return ZStack(alignment: .leading) {
            Text("\(glyph) \(TimeLabel.widestScanSpeed(duration: model.duration))").hidden()
            Text("\(glyph) \(TimeLabel.scanSpeed(speed))")
                .contentTransition(.numericText(value: abs(speed)))
        }
        .font(.caption.weight(.bold))
    }
    #endif

    /// On Apple TV, as near the previews' own pixels as 260 to 320 points allows: 640-pixel previews
    /// at 320 points on a 4K TV, and 320-pixel ones at 260 rather than blown up twice over.
    /// Elsewhere half the width the player asks for, its pixels on a 2× screen.
    private static func thumbnailWidth(of tiles: TrickplayTiles?, scale: CGFloat) -> CGFloat {
        #if os(tvOS)
        guard let tiles else { return 320 }
        return min(320, max(260, CGFloat(tiles.info.width) / max(1, scale)))
        #else
        CGFloat(TrickplayTiles.preferredWidth) / 2
        #endif
    }

    private static var spacing: CGFloat {
        #if os(tvOS)
        8
        #else
        4
        #endif
    }

    private static var captionSpacing: CGFloat {
        #if os(tvOS)
        12
        #else
        6
        #endif
    }

    private static var thumbnailRadius: CGFloat {
        #if os(tvOS)
        12
        #else
        8
        #endif
    }
}

/// The sum of the skips in a row: "+30", "−1:00". On Apple TV over the playhead, with the way it
/// went; elsewhere over the skip button, or the side of the picture double-tapped, which show
/// the way themselves.
struct SkipTally: View {
    let seconds: Double

    var body: some View {
        Label(text, systemImage: seconds < 0 ? "gobackward" : "goforward")
            #if !os(tvOS)
            .labelStyle(.titleOnly)
            #endif
            .font(Self.font)
            .monospacedDigit()
            .contentTransition(.numericText(value: seconds))
            .padding(.horizontal, Self.padding.width)
            .padding(.vertical, Self.padding.height)
            .platformGlass(in: .capsule)
            .accessibilityHidden(true)
    }

    #if os(tvOS)
    /// Kept this far from the timeline's ends, about half its width.
    static let halfWidth: CGFloat = 80
    private static let font = Font.callout.weight(.semibold)
    private static let padding = CGSize(width: 20, height: 10)
    #else
    private static let font = Font.subheadline.weight(.semibold)
    private static let padding = CGSize(width: 12, height: 6)
    #endif

    private var text: String {
        let magnitude = abs(seconds)
        let amount = magnitude < 60 ? String(Int(magnitude.rounded())) : Scrubber.format(magnitude)
        return (seconds < 0 ? "\u{2212}" : "+") + amount
    }
}

/// One thumbnail cut from its sheet of scrub previews, which comes from the image cache, or from
/// disk for a download.
private struct TrickplayThumbnail: View {
    let tiles: TrickplayTiles
    let time: Double
    @State private var sheet: (index: Int, image: CGImage)?
    /// The sheet that couldn't be loaded, whose thumbnails say so.
    @State private var failedSheet: Int?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    var body: some View {
        let spot = tiles.thumbnail(at: time)
        Group {
            if let spot, let sheet, sheet.index == spot.sheet, let thumbnail = sheet.image.cropping(to: spot.rect) {
                Image(decorative: thumbnail, scale: 1).resizable()
            } else {
                Rectangle().fill(.black.opacity(0.6))
                    .overlay {
                        if let spot, failedSheet == spot.sheet {
                            Text("No preview").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .aspectRatio(CGFloat(tiles.info.width) / CGFloat(max(1, tiles.info.height)), contentMode: .fit)
        .task(id: spot?.sheet) {
            guard let index = spot?.sheet, sheet?.index != index else { return }
            do {
                let image = try await ImagePipeline.shared.image(for: tiles.sheets[index])
                #if os(macOS)
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                let cgImage = image.cgImage
                #endif
                if let cgImage {
                    sheet = (index, cgImage)
                } else {
                    Self.log.notice("Scrub preview sheet \(index) has no bitmap")
                    failedSheet = index
                }
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.notice("Couldn't load scrub previews: \(error.localizedDescription, privacy: .public)")
                failedSheet = index
            }
        }
    }
}

/// A timeline's bar: how far along and how much is buffered, with `marks` (as chapters' starts)
/// and, but on Apple TV, a handle to drag. `position` follows the drag, and `onSeek` gets where
/// it let go; without `onSeek` the bar takes no drags, as when the timeline around it takes them.
struct TimelineBar: View {
    let time: Double
    var buffered: Double = 0
    let duration: Double
    let color: Color
    let height: CGFloat
    var marks: [Double] = []
    /// A playhead at the position, and while the position is moved, a mark where playback is.
    var showsHead = false
    @Binding var position: Double?
    var onDrag: () -> Void = {}
    let onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let offset = { (seconds: Double) in width * min(1, max(0, seconds / duration)) }
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.25))
                Capsule().fill(color.opacity(0.4))
                    .frame(width: offset(buffered))
                Capsule().fill(color)
                    .frame(width: offset(position ?? time))
                ForEach(marks.filter { $0 > 0 && $0 < duration }, id: \.self) { mark in
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: offset(mark) - 1)
                }
            }
            .frame(height: height)
            // Over the bar rather than in it, which would make the bar as tall as the playhead.
            .overlay(alignment: .leading) {
                if showsHead {
                    if position != nil {
                        Capsule().fill(color.opacity(0.6))
                            .frame(width: 3, height: height * 2)
                            .offset(x: offset(time) - 1.5)
                    }
                    Capsule().fill(color)
                        .frame(width: 4, height: height * 2.6)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: offset(position ?? time) - 2)
                }
            }
            .frame(maxHeight: .infinity)
        }
        #if !os(tvOS)
        .timelineDragging(duration: duration, time: time, position: $position, snapPoints: marks, onDrag: onDrag, onSeek: onSeek)
        #endif
    }
}

#if !os(tvOS)
private extension View {
    /// A finger on the view, from its leading edge to its trailing one, places `position` within
    /// `duration` (`TimelineDrag`): a drag moves it from where it was, `time` until it moves, and
    /// slower as the finger slides up, holding at `snapPoints` on the way; a tap jumps. `rate` is
    /// the drag's speed. `onSeek` gets where it let go. Without `onSeek` the view takes no drag.
    func timelineDragging(duration: Double, time: Double, position: Binding<Double?>, rate: Binding<Double>? = nil,
                          snapPoints: [Double] = [], onDrag: @escaping () -> Void,
                          onSeek: ((Double) -> Void)?) -> some View {
        modifier(TimelineDragging(duration: duration, time: time, position: position, rate: rate, snapPoints: snapPoints,
                                  onDrag: onDrag, onSeek: onSeek))
    }
}

private struct TimelineDragging: ViewModifier {
    let duration: Double
    let time: Double
    @Binding var position: Double?
    let rate: Binding<Double>?
    let snapPoints: [Double]
    let onDrag: () -> Void
    let onSeek: ((Double) -> Void)?
    @State private var width: CGFloat = 0
    /// The drag under way, once the finger has moved far enough to be one.
    @State private var drag: TimelineDrag?

    func body(content: Content) -> some View {
        if let onSeek {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            let moved = hypot(value.translation.width, value.translation.height)
                            if drag == nil {
                                // Until it moves, the touch may be a tap.
                                guard moved >= TimelineDrag.tapSlop else { return }
                                drag = TimelineDrag(startX: value.startLocation.x, position: position ?? time,
                                                    duration: duration, width: width)
                            }
                            guard var current = drag else { return }
                            current.move(toX: value.location.x, rise: value.startLocation.y - value.location.y)
                            drag = current
                            position = ChapterSnap.snapped(current.position, to: snapPoints,
                                                           within: current.seconds(forPoints: ChapterSnap.reach))
                            if let rate, rate.wrappedValue != current.rate { rate.wrappedValue = current.rate }
                            onDrag()
                        }
                        .onEnded { value in
                            if drag == nil {
                                onSeek(TimelineDrag.tapPosition(x: value.location.x, width: width, duration: duration))
                            } else if let position {
                                onSeek(position)
                            }
                            drag = nil
                            position = nil
                            if let rate, rate.wrappedValue != 1 { rate.wrappedValue = 1 }
                        }
                )
        } else {
            content
        }
    }
}
#endif
