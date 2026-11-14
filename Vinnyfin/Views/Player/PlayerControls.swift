import AetherEngine
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
    /// Nil when Picture in Picture isn't possible right now.
    let pictureInPicture: (() -> Void)?
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
        #if os(tvOS)
        .defaultFocus(focus, .timeline)
        .onChange(of: focus.wrappedValue) { onInteraction() }
        // Back to the button that opened a panel once it closes.
        .onChange(of: panel) { closed, opened in
            if opened == nil, let closed { focus.wrappedValue = .panel(closed) }
        }
        .animation(.easeInOut(duration: 0.25), value: isCompact)
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
                .init(color: .black.opacity(0.6), location: 0.78),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                    .opacity(showsOnlyTimeline ? 0 : 1)
                    .accessibilityHidden(showsOnlyTimeline)
                Spacer()
                #if !os(tvOS)
                transport
                Spacer()
                #endif
                bottomBar
            }
            .padding(.horizontal, Metrics.playerInset)
            .padding(.vertical, 12)
        }
    }

    #if os(iOS)
    private var belowFold: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                topBar
                bottomBar
                transport
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
                bottomBar
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
                    FormatBadge(model: model).padding(.top, 6)
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
                        Button(action: pictureInPicture) {
                            symbol("pip.enter")
                        }
                        .buttonStyle(.platformGlass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .accessibilityLabel("Picture in Picture")
                        .accessibilityShowsLargeContentViewer()
                    }
                    #endif
                    #if os(iOS)
                    // Last, where it shows by itself as the phone turns.
                    RotateButton(onUse: onInteraction)
                    #endif
                }
                .dynamicTypeSize(...Self.largestControlSize)
            }
            if isTitleOwnRow { titleBlock }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
    }

    /// Like the system player's, the buttons keep their size past the default text size, where a
    /// row of them would run off the screen; the Large Content Viewer shows each one large.
    private static let largestControlSize = DynamicTypeSize.large

    /// At the accessibility sizes the title gets a row of its own, under the buttons, rather than
    /// a word or two between them.
    private var isTitleOwnRow: Bool { dynamicTypeSize.isAccessibilitySize }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title).font(.headline).lineLimit(dynamicTypeSize.lineLimit(1))
                .accessibilityAddTraits(.isHeader)
            if let subtitle = model.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(1))
            }
        }
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
            transportButton("gobackward.10", label: "Back 10 Seconds", size: 30 * scale) { model.skip(by: -PlayerModel.skipInterval) }
            transportButton(playPauseSymbol, label: playPauseLabel, size: 44 * scale, showsProgress: isWaiting) {
                model.togglePlayPause()
            }
            .accessibilityIdentifier("player.playPause")
            transportButton("goforward.10", label: "Forward 10 Seconds", size: 30 * scale) { model.skip(by: PlayerModel.skipInterval) }
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, showsProgress: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Group {
                if showsProgress {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size * 1.6, height: size * 1.6)
        }
        .buttonStyle(.platformGlass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer()
    }
    #endif

    /// Loading or refilling the buffer: the play button turns into the spinner.
    private var isWaiting: Bool {
        switch model.status {
        case .preparing, .loading, .buffering: true
        default: false
        }
    }

    private var playPauseLabel: String {
        switch model.status {
        case .ended: "Play Again"
        default: model.isPlaying ? "Pause" : "Play"
        }
    }

    private var playPauseSymbol: String {
        switch model.status {
        case .ended: "arrow.counterclockwise"
        default: model.isPlaying ? "pause.fill" : "play.fill"
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
                Spacer()
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

    @ViewBuilder private var trackMenus: some View {
        panelButton(.audio, identifier: "player.audio", value: model.audioOptions.first { $0.id == model.selectedAudio }?.title)
            .disabled(model.audioOptions.isEmpty)
        panelButton(.subtitles, identifier: "player.subtitles", filled: model.selectedSubtitle != nil,
                    value: model.subtitleOptions.first { $0.id == model.selectedSubtitle }?.title ?? "Off")
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
    }
}

/// What's on screen when it's worth saying: a speed other than 1×, 3D, Dolby Vision, HDR, or
/// that the server is transcoding.
private struct FormatBadge: View {
    let model: PlayerModel
    #if os(visionOS)
    @Environment(PlayerCoordinator.self) private var coordinator
    #endif

    var body: some View {
        if let text {
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

    var body: some View {
        @Bindable var scrubbing = model.scrubbing
        let duration = max(model.duration, 1)
        let position = scrubbing.position
        let time = position ?? model.clock.time
        VStack(spacing: 6) {
            TimelineBar(time: model.clock.time, buffered: model.clock.buffered, duration: duration, color: .white,
                        height: barHeight, marks: model.chapters.map(\.start), showsHead: showsHead,
                        position: $scrubbing.position, onDrag: onInteraction) { model.seek(to: $0) }
                .overlay { overBar(position: position, duration: duration) }
            #if os(visionOS)
            // Tall enough to look at and pinch, and lit under the eyes as a slider is.
            .frame(height: 44)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
            #else
            .frame(height: 24)
            #endif
            HStack {
                Text(Self.format(time)).monospacedDigit()
                Spacer()
                Text("-" + Self.format(max(0, duration - time))).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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

    /// Over the bar: the preview while the timeline moves, and on Apple TV the run of skips.
    private func overBar(position: Double?, duration: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // Its bottom clear of the bar, its own height rather than the bar's.
            let above = -(geometry.size.height + barHeight) / 2 - 8
            if let position {
                let center = width * min(1, max(0, position / duration))
                ScrubPreview(model: model, time: position)
                    // Centered over the handle, kept within the timeline.
                    .offset(x: min(max(0, center - ScrubPreview.width / 2), max(0, width - ScrubPreview.width)), y: above)
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

    /// Apple TV marks the playhead where the remote moves it from.
    private var showsHead: Bool {
        #if os(tvOS)
        isFocused || model.scrubbing.isActive
        #else
        false
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

/// Over the timeline while it moves: the picture at that point, when the server made scrub
/// previews, with the chapter and the time under it. On Apple TV, also how far that is from where
/// playback is, and the speed of a held side scanning.
private struct ScrubPreview: View {
    let model: PlayerModel
    let time: Double

    var body: some View {
        let chapter = ChapterMark.current(in: model.chapters, at: time)
        VStack(spacing: Self.spacing) {
            if let tiles = model.trickplay {
                TrickplayThumbnail(tiles: tiles, time: time)
                    .frame(width: Self.thumbnailWidth,
                           height: Self.thumbnailWidth * CGFloat(tiles.info.height) / CGFloat(max(1, tiles.info.width)))
                    .clipShape(.rect(cornerRadius: Self.thumbnailRadius))
            }
            if let chapter {
                Text(chapter.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
            #if os(tvOS)
            HStack(spacing: 12) {
                if let speed = model.scrubbing.scanSpeed {
                    Label("\(Int(abs(speed)))×", systemImage: speed < 0 ? "backward.fill" : "forward.fill")
                        .font(.caption.weight(.bold))
                        .contentTransition(.numericText())
                }
                Text(Scrubber.format(time)).font(.caption.weight(.semibold)).monospacedDigit()
                Text(Self.distance(time - model.clock.time)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .lineLimit(1)
            #else
            Text(Scrubber.format(time)).font(.caption).monospacedDigit()
            #endif
        }
        .padding(model.trickplay == nil ? Self.spacing * 2 : Self.spacing)
        .frame(minWidth: Self.width)
        // Its own height, not the timeline's it's laid over.
        .fixedSize()
        .platformGlass(in: .rect(cornerRadius: Self.thumbnailRadius + Self.spacing))
        .accessibilityHidden(true)
    }

    static var width: CGFloat { thumbnailWidth + 2 * spacing }

    private static var thumbnailWidth: CGFloat {
        #if os(tvOS)
        320
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

    private static var thumbnailRadius: CGFloat {
        #if os(tvOS)
        12
        #else
        8
        #endif
    }

    /// "+2:15" ahead of where playback is, "-0:40" behind it.
    static func distance(_ seconds: Double) -> String {
        (seconds < 0 ? "-" : "+") + Scrubber.format(abs(seconds))
    }
}

#if os(tvOS)
/// The sum of the skips in a row, over the playhead: "+30", "-1:00".
private struct SkipTally: View {
    let seconds: Double

    var body: some View {
        Label(text, systemImage: seconds < 0 ? "gobackward" : "goforward")
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: seconds))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .platformGlass(in: .capsule)
            .accessibilityHidden(true)
    }

    /// Kept this far from the timeline's ends, about half its width.
    static let halfWidth: CGFloat = 80

    private var text: String {
        let magnitude = abs(seconds)
        let amount = magnitude < 60 ? String(Int(magnitude.rounded())) : Scrubber.format(magnitude)
        return (seconds < 0 ? "-" : "+") + amount
    }
}
#endif

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
/// it let go.
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
    let onSeek: (Double) -> Void

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
            #if !os(tvOS)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        position = min(duration, max(0, value.location.x / width * duration))
                        onDrag()
                    }
                    .onEnded { _ in
                        if let position { onSeek(position) }
                        self.position = nil
                    }
            )
            #endif
        }
    }
}
