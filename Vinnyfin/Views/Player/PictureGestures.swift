#if os(macOS)
import AppKit
#endif
import SwiftUI

/// What taps on the picture do. The first tap of any run shows or hides the controls at once,
/// never waiting to see whether another follows. On a touchscreen a second tap soon after, on the
/// same side third of the picture, skips back or forward instead, and puts the controls back as
/// they were before the first; each tap after that on either side skips again while the taps keep
/// coming. The middle third only ever shows and hides the controls. On the Mac a double click
/// toggles full screen, putting the controls back as they were.
nonisolated struct PictureTaps {
    enum Mode {
        /// Double taps on the sides skip: iPhone and iPad.
        case sideSkips
        /// A double click toggles full screen: the Mac.
        case doubleClickFullScreen
        /// Each tap shows or hides the controls.
        case toggleOnly
    }

    enum Zone {
        case back, middle, forward
    }

    enum Action: Equatable {
        case toggleControls
        /// Skip, first putting the controls back as they were before the run's first tap when
        /// `restoresControls`.
        case skip(forward: Bool, restoresControls: Bool)
        /// Toggle full screen, putting the controls back as they were before the first click.
        case fullScreen
    }

    /// How soon a second tap follows the first to make a double tap, as the system's own.
    static let doubleTapInterval: Double = 0.3
    /// How soon each tap follows the last to keep a run of skips going.
    static let runInterval: Double = 0.7

    let mode: Mode
    let doubleTapInterval: Double
    private var last: (time: Double, zone: Zone)?
    private var isSkipping = false

    init(mode: Mode, doubleTapInterval: Double = Self.doubleTapInterval) {
        self.mode = mode
        self.doubleTapInterval = doubleTapInterval
    }

    /// The third of a picture `width` wide that `x` is in.
    static func zone(x: Double, width: Double) -> Zone {
        guard width > 0 else { return .middle }
        let share = x / width
        if share < 1.0 / 3 { return .back }
        if share > 2.0 / 3 { return .forward }
        return .middle
    }

    /// A tap at `time`, in seconds on any steady clock, in `zone`. `canSkip` says there's a
    /// timeline to skip along, and the run's first tap didn't close a panel.
    mutating func tap(at time: Double, zone: Zone, canSkip: Bool) -> Action {
        let gap = last.map { time - $0.time } ?? .infinity
        let previous = last
        last = (time, zone)
        switch mode {
        case .toggleOnly:
            return .toggleControls
        case .doubleClickFullScreen:
            guard gap <= doubleTapInterval else { return .toggleControls }
            // A third click starts over.
            last = nil
            return .fullScreen
        case .sideSkips:
            guard canSkip, zone != .middle else {
                isSkipping = false
                return .toggleControls
            }
            if isSkipping, gap <= Self.runInterval {
                return .skip(forward: zone == .forward, restoresControls: false)
            }
            isSkipping = false
            if gap <= doubleTapInterval, previous?.zone == zone {
                isSkipping = true
                return .skip(forward: zone == .forward, restoresControls: true)
            }
            return .toggleControls
        }
    }
}

#if os(iOS)
/// The picture's touches on iPhone and iPad: taps (`PictureTaps`), a press held to play at twice
/// the speed until let go, a pull down to close, and a pinch to fill the screen or fit it.
struct PictureTouches: ViewModifier {
    /// A tap, where it was in the picture, and the picture's width.
    let onTap: (_ x: CGFloat, _ width: CGFloat) -> Void
    let onHoldBegan: () -> Void
    let onHoldEnded: () -> Void
    /// Pulling down is on: off while a panel is open.
    let canPull: Bool
    /// How far down the picture has been pulled, as it follows the finger.
    @Binding var pull: CGFloat
    let onPulledAway: () -> Void
    let onPinch: (_ magnification: CGFloat) -> Void
    @State private var width: CGFloat = 0
    @State private var isHolding = false
    /// When the press held last let go: the lift that ends a hold isn't a tap.
    @State private var holdEnded: Date?

    /// How long a press is held before it plays faster.
    static let holdDuration = 0.4
    /// How far a pull goes, or would go at its speed, to close.
    static let pullDistance: CGFloat = 120
    static let pullFling: CGFloat = 320

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if isHolding { return }
                        if let holdEnded, Date.now.timeIntervalSince(holdEnded) < 0.3 { return }
                        onTap(value.location.x, width)
                    }
            )
            .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 12) {
                isHolding = true
                onHoldBegan()
            } onPressingChanged: { pressing in
                guard !pressing, isHolding else { return }
                isHolding = false
                holdEnded = .now
                onHoldEnded()
            }
            .simultaneousGesture(
                // In the screen's coordinates: the picture moves down with the finger, so in its
                // own the finger would seem to go half as far.
                DragGesture(minimumDistance: 16, coordinateSpace: .global)
                    .onChanged { value in
                        guard canPull, !isHolding else { return }
                        let down = value.translation.height
                        // Started mostly down; sideways or up, the picture stays.
                        guard pull > 0 || down > abs(value.translation.width) else { return }
                        pull = max(0, down)
                    }
                    .onEnded { value in
                        guard pull > 0 else { return }
                        if value.translation.height > Self.pullDistance || value.predictedEndTranslation.height > Self.pullFling {
                            onPulledAway()
                        } else {
                            withAnimation(.snappy) { pull = 0 }
                        }
                    }
            )
            .simultaneousGesture(MagnifyGesture().onEnded { onPinch($0.magnification) })
    }
}

/// Over the side of the picture a double tap skipped on: a wash of light rippling from the side
/// at each tap, the way it went, and, with the controls hidden, the run's sum. With the controls
/// up, the sum is over the skip button instead.
struct SkipRipple: View {
    let forward: Bool
    /// The run's sum, negative going back.
    let seconds: Double
    /// Counts the taps, each of which ripples.
    let taps: Int
    let showsTally: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let side = min(size.width * 0.42, 360)
            ZStack {
                Ellipse()
                    .fill(.white.opacity(0.14))
                    .frame(width: side * 2, height: max(size.height * 1.3, side * 2))
                    .keyframeAnimator(initialValue: 0.0, trigger: taps) { wash, lift in
                        wash.opacity(0.6 + 0.4 * lift)
                    } keyframes: { _ in
                        LinearKeyframe(1, duration: 0.08)
                        LinearKeyframe(0, duration: 0.4)
                    }
                    .position(x: forward ? size.width + side * 0.25 : -side * 0.25, y: size.height / 2)
                VStack(spacing: 10) {
                    Image(systemName: forward ? "forward.fill" : "backward.fill")
                        .font(.title2)
                        .symbolEffect(.bounce.byLayer, options: .speed(1.6), value: reduceMotion ? 0 : taps)
                    if showsTally {
                        SkipTally(seconds: seconds)
                            .fixedSize()
                    }
                }
                .foregroundStyle(.white)
                .position(x: forward ? size.width - side * 0.45 : side * 0.45, y: size.height / 2)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif

#if !os(tvOS)
/// A word over the top of the picture for a moment: the speed held, or the volume set.
struct PlayerFlash: View {
    enum Kind: Equatable {
        /// A press held on the picture plays at this speed.
        case speed(Float)
        /// The volume, from nothing to 1.
        case volume(Float, isMuted: Bool)
    }

    let kind: Kind
    /// The bottom of the controls' top bar in global coordinates while they show, which it keeps below.
    var controlsBottom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let clearBelow = controlsBottom.map { max(0, $0 - geometry.frame(in: .global).minY) } ?? 0
            label
                .padding(.top, clearBelow + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        Group {
            switch kind {
            case .speed(let speed):
                Label(PlaybackSpeed.label(speed), systemImage: "forward.fill")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            case .volume(let level, let isMuted):
                HStack(spacing: 10) {
                    Image(systemName: isMuted || level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: Double(level))
                        .frame(width: 26)
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: 140 * CGFloat(isMuted ? 0 : level))
                        }
                        .frame(width: 140, height: 6)
                }
                .font(.callout.weight(.semibold))
                .animation(.easeOut(duration: 0.15), value: level)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
    }
}
#endif

/// The Mac's player window, shaped like its picture: how small it goes, and how it takes the shape
/// of a new picture without leaving the screen. Sizes are the window's content, in points.
nonisolated enum PlayerWindowFrame {
    /// Along the picture's long side and its short side, the least the controls fit in.
    static let longSide: CGFloat = 480
    static let shortSide: CGFloat = 270

    /// The width over the height of a picture `size` big; 16:9 until it's known.
    static func aspect(of size: CGSize?) -> CGFloat {
        guard let size, size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    /// The smallest window of a picture `aspect` wide for its height: at least `longSide` along
    /// its long side and `shortSide` along its short one. Small enough for any Mac's screen
    /// whatever the shape, which a minimum width alone isn't for a tall picture.
    static func minimumSize(aspect: CGFloat) -> CGSize {
        if aspect >= 1 {
            let width = max(longSide, shortSide * aspect)
            return CGSize(width: width, height: width / aspect)
        }
        let height = max(longSide, shortSide / aspect)
        return CGSize(width: height * aspect, height: height)
    }

    /// The window's frame for a picture `aspect` wide for its height, from its frame `current`,
    /// on a screen whose area for windows is `visible`. `chrome` is how much bigger the frame is
    /// than the content, which has the picture's shape. The window keeps its width, unless the
    /// picture's height at that width is more than the screen has room for: then it's as tall
    /// as there's room, as wide as the shape makes that, and never smaller than `minimumSize`
    /// but where the screen is smaller still. Its top stays where it was, and then it moves
    /// onto the screen where it's off it.
    static func frame(from current: CGRect, aspect: CGFloat, chrome: CGSize = .zero, on visible: CGRect) -> CGRect {
        guard aspect > 0 else { return current }
        let room = CGSize(width: max(1, visible.width - chrome.width), height: max(1, visible.height - chrome.height))
        let minimum = minimumSize(aspect: aspect)
        var width = max(current.width - chrome.width, minimum.width)
        width = min(width, room.width, room.height * aspect)
        let content = CGSize(width: width.rounded(), height: (width / aspect).rounded())
        let size = CGSize(width: content.width + chrome.width, height: content.height + chrome.height)
        let top = current.maxY
        var origin = CGPoint(x: current.minX, y: top - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

#if os(macOS)
extension EnvironmentValues {
    /// The player's window is in full screen.
    @Entry var playerIsFullScreen = false
}

/// The player window: kept to the picture's shape as it's resized, and turned to the shape of
/// each new picture within its screen (`PlayerWindowFrame`), and followed in and out of full
/// screen.
struct PlayerWindowShape: NSViewRepresentable {
    /// The picture's shape; nil until it's known.
    let videoSize: CGSize?
    let onFullScreenChange: (Bool) -> Void

    func makeNSView(context: Context) -> ShapeView {
        ShapeView()
    }

    func updateNSView(_ view: ShapeView, context: Context) {
        view.onFullScreenChange = onFullScreenChange
        view.videoSize = videoSize
    }

    final class ShapeView: NSView {
        var onFullScreenChange: (Bool) -> Void = { _ in }
        var videoSize: CGSize? {
            didSet {
                guard videoSize != oldValue else { return }
                // Once SwiftUI has given the window the new shape's minimum size
                // (`PlayerWindow`): a frame below the old one's would be pushed back out to it.
                DispatchQueue.main.async { [weak self] in self?.applyShape() }
            }
        }
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for (name, isFullScreen) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onFullScreenChange(isFullScreen) }
                })
            }
            onFullScreenChange(window.styleMask.contains(.fullScreen))
            applyShape()
        }

        /// Gives the window the picture's shape on its screen; in full screen the system
        /// letterboxes it instead.
        private func applyShape() {
            guard let window, let videoSize, videoSize.width > 0, videoSize.height > 0 else { return }
            window.contentAspectRatio = videoSize
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let chrome = CGSize(width: window.frame.width - content.width, height: window.frame.height - content.height)
            let frame = PlayerWindowFrame.frame(from: window.frame, aspect: PlayerWindowFrame.aspect(of: videoSize),
                                                chrome: chrome, on: screen.visibleFrame)
            let current = window.frame
            guard abs(frame.minX - current.minX) > 1 || abs(frame.maxY - current.maxY) > 1
                    || abs(frame.width - current.width) > 1 || abs(frame.height - current.height) > 1 else { return }
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
#endif
