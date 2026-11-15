#if os(iOS)
import AVFoundation
import CoreImage
import SwiftUI

/// Water rippling over the picture from where it was double-tapped to skip: the picture as it
/// plays, frame by frame, bent by `waterRipple` (WaterRipple.metal) and laid over the picture only
/// where the water moves, so the rest plays on around it. The frames come from an output on the
/// engine's AVPlayer item, read only while the water moves. A picture the engine draws itself, as
/// a codec AVPlayer can't play, has none: SwiftUI's shaders can't read a video layer, so that one
/// ripples with light alone (`SkipRipple`).
@Observable
final class PictureRipples {
    struct Ripple {
        /// Where it began, in the player's layers (`playerPicture`).
        let origin: CGPoint
        let began: Date
    }

    /// The picture as the water bends it: the frame playing, a moment behind.
    private(set) var frame: CGImage?
    private(set) var ripples: [Ripple] = []

    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private weak var item: AVPlayerItem?
    /// The frame last read, which stays the one on screen while the picture is still.
    @ObservationIgnored private var lastBuffer: CVPixelBuffer?
    @ObservationIgnored private var clearing: Task<Void, Never>?
    /// Reads each new frame while the water moves, in step with the screen.
    @ObservationIgnored private var displayLink: CADisplayLink?
    /// A frame is being made into a picture; the newest to come meanwhile waits its turn.
    @ObservationIgnored private var isMaking = false
    @ObservationIgnored private var waiting: CVPixelBuffer?

    /// How long a ripple takes to settle.
    static let lifetime: Duration = .seconds(1.4)
    /// The ripples at once, a tap's each: older ones give way.
    static let most = 3

    /// Reads frames from `item`, the engine's AVPlayer item as it changes; nil when the engine
    /// draws the picture itself, or the player closes.
    func attach(to item: AVPlayerItem?) {
        guard item !== self.item || item == nil else { return }
        if let output, let old = self.item { old.remove(output) }
        output = nil
        lastBuffer = nil
        settle()
        self.item = item
        guard let item else { return }
        // In the picture's own format, so nothing is converted for frames that go unread.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        self.output = output
    }

    /// A double tap at `origin`, in the player's layers: ripples the picture from there. False
    /// when there's no frame to bend.
    func splash(at origin: CGPoint) -> Bool {
        let ripple = { [self] in
            ripples = Array((ripples + [Ripple(origin: origin, began: .now)]).suffix(Self.most))
            clearing?.cancel()
            clearing = Task {
                try? await Task.sleep(for: Self.lifetime)
                guard !Task.isCancelled else { return }
                settle()
            }
        }
        // The water already moving bends the picture as it plays.
        if frame != nil, displayLink != nil {
            ripple()
            return true
        }
        guard let buffer = displayedBuffer() else { return false }
        Task {
            guard let image = await Self.image(of: FrameBuffer(buffer: buffer)) else { return }
            frame = image
            ripple()
            follow()
        }
        return true
    }

    /// The water still: no more frames are read, and what's over the picture goes.
    private func settle() {
        clearing?.cancel()
        displayLink?.invalidate()
        displayLink = nil
        waiting = nil
        ripples = []
        frame = nil
    }

    /// Reads the frames as they play, each as the screen is about to show it, while the water moves.
    private func follow() {
        guard displayLink == nil, !ripples.isEmpty else { return }
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] link in self?.tick(link) },
                                 selector: #selector(DisplayLinkTarget.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func tick(_ link: CADisplayLink) {
        guard let output else { return }
        let time = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        lastBuffer = buffer
        make(buffer)
    }

    /// Makes `buffer` the picture the water bends, after the one being made, if any: frames that
    /// come meanwhile give way to the newest.
    private func make(_ buffer: CVPixelBuffer) {
        guard !isMaking else {
            waiting = buffer
            return
        }
        isMaking = true
        Task {
            let image = await Self.image(of: FrameBuffer(buffer: buffer))
            isMaking = false
            // Settled meanwhile, the water has gone.
            if let image, !ripples.isEmpty { frame = image }
            if let next = waiting, !ripples.isEmpty {
                waiting = nil
                make(next)
            }
        }
    }

    private func displayedBuffer() -> CVPixelBuffer? {
        guard let output else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) { lastBuffer = buffer }
        return lastBuffer
    }

    private nonisolated struct FrameBuffer: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// No wider than this: the water blurs what it bends, and a smaller frame is quicker to make.
    private nonisolated static let widest: CGFloat = 1280
    /// Every frame is new: nothing is kept between them.
    private nonisolated static let context = CIContext(options: [.cacheIntermediates: false])
    private nonisolated static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    /// Made here, off the main thread, rather than as the picture is drawn.
    @concurrent
    private nonisolated static func image(of frame: FrameBuffer) async -> CGImage? {
        var image = CIImage(cvPixelBuffer: frame.buffer)
        let scale = min(1, widest / max(1, image.extent.width))
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB, deferred: false)
    }
}

/// A display link's target, which it keeps: calls back without keeping what it calls.
private final class DisplayLinkTarget: NSObject {
    let onFire: (CADisplayLink) -> Void

    init(_ onFire: @escaping (CADisplayLink) -> Void) {
        self.onFire = onFire
    }

    @objc func fire(_ link: CADisplayLink) {
        onFire(link)
    }
}

/// The water over the picture while it ripples (`PictureRipples`), placed as the picture is: fit
/// to the view, or filling it.
struct PictureRippleView: View {
    let ripples: PictureRipples
    /// The picture's width over its height; the frame's own until it's known.
    let aspect: CGFloat?
    let fillsScreen: Bool

    var body: some View {
        if let frame = ripples.frame, !ripples.ripples.isEmpty {
            GeometryReader { geometry in
                // The ripples began in the player's layers; the water is drawn in this view's.
                let origin = geometry.frame(in: .playerPicture).origin
                TimelineView(.animation) { context in
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(aspect ?? CGFloat(frame.width) / CGFloat(max(1, frame.height)),
                                     contentMode: fillsScreen ? .fill : .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .layerEffect(Self.water(ripples.ripples, from: origin, at: context.date), maxSampleOffset: Self.reach)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// How far the steepest wave moves the picture, in points.
    private static let amplitude: Float = 14
    /// Room for the picture to move into view from beyond the edges: the waves of every ripple
    /// at once, red bent furthest.
    private static let reach = CGSize(width: CGFloat(amplitude) * 1.4 * CGFloat(PictureRipples.most),
                                      height: CGFloat(amplitude) * 1.4 * CGFloat(PictureRipples.most))

    /// The water of `ripples`, placed in a view at `origin` in the player's layers.
    private static func water(_ ripples: [PictureRipples.Ripple], from origin: CGPoint, at date: Date) -> Shader {
        let values = ripples.flatMap { ripple in
            [Float(ripple.origin.x - origin.x), Float(ripple.origin.y - origin.y), Float(date.timeIntervalSince(ripple.began))]
        }
        return ShaderLibrary.waterRipple(.floatArray(values), .float(amplitude), .float(56), .float(640),
                                         .float(2.2), .float(0.35))
    }
}
#endif
