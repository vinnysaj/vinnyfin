import Foundation
#if os(tvOS)
import UIKit
#endif

/// The most a stream on this device may be: the streaming quality, held lower by what the display
/// makes use of and by the bitrate the connection was learned to carry.
nonisolated struct StreamingLimit: Equatable, Sendable {
    var quality: VideoQuality
    /// The tallest picture the display makes use of, in lines; nil when it makes use of any.
    var displayHeight: Int?
    /// Bits per second, from `QualityLearning`; nil when nothing was learned.
    var bitrate: Int?

    init(quality: VideoQuality, displayHeight: Int? = nil, bitrate: Int? = nil) {
        self.quality = quality
        self.displayHeight = displayHeight
        self.bitrate = bitrate
    }

    /// The tallest picture to stream, in lines; nil when there's no limit.
    var maxHeight: Int? {
        [quality.maxHeight, displayHeight].compactMap(\.self).min()
    }

    /// Whether a version is within the limit; nil when what would tell isn't known, as for a
    /// version without a size, or without a bitrate when there's one to keep to.
    func admits(_ traits: VersionTraits) -> Bool? {
        var isKnown = true
        if let maxHeight {
            if let resolution = traits.resolutionClass {
                if resolution > maxHeight { return false }
            } else {
                isKnown = false
            }
        }
        if let bitrate {
            if let measured = traits.bitrate {
                if measured > bitrate { return false }
            } else {
                isKnown = false
            }
        }
        return isKnown ? true : nil
    }

    /// How far a version is over the limit, for taking the least over when none is within it: a
    /// picture that fits ranks first, then the smaller picture, then, with a bitrate to keep to,
    /// the lower bitrate.
    func excess(_ traits: VersionTraits) -> (Int, Int) {
        let height = maxHeight.flatMap { cap in traits.resolutionClass.flatMap { $0 > cap ? $0 : nil } } ?? 0
        return (height, bitrate == nil ? 0 : traits.bitrate ?? .max)
    }

    /// The size a transcode within the limit is made at: the largest whose picture and bitrate
    /// fit it, else the smallest. Nil when nothing limits the stream.
    var transcodeQuality: VideoQuality? {
        guard maxHeight != nil || bitrate != nil else { return nil }
        return VideoQuality.limited.first { quality in
            (maxHeight.map { (quality.maxHeight ?? .max) <= $0 } ?? true) && (bitrate.map { quality.transcodeBitrate <= $0 } ?? true)
        } ?? VideoQuality.limited.last
    }
}

/// What the display makes use of, where that bears on what's worth streaming.
enum DisplayOutput {
    /// The tallest picture worth streaming to the display, in lines: on Apple TV, 1080 while it
    /// outputs 1080p or less, where a 4K picture would only be scaled down. Nil when it outputs
    /// more, and on the other devices, whose windows, external displays and AirPlay make their
    /// own screen no guide.
    static var streamingHeight: Int? {
        #if os(tvOS)
        streamingHeight(forOutputHeight: outputHeight)
        #else
        nil
        #endif
    }

    /// The tallest picture worth streaming to an output `height` lines tall: anything up to 1080p
    /// makes use of no more than 1080p.
    nonisolated static func streamingHeight(forOutputHeight height: Int?) -> Int? {
        guard let height, height <= 1080 else { return nil }
        return 1080
    }

    #if os(tvOS)
    /// The lines the Apple TV sends the TV: its screen's size in pixels, which is the format
    /// Settings › Video and Audio chose for the TV. Match Content switches the frame rate and the
    /// dynamic range, never this. Nil before the app has a scene on the screen.
    static var outputHeight: Int? {
        let screen = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
        guard let size = screen?.nativeBounds.size, size.width > 0, size.height > 0 else { return nil }
        return Int(min(size.width, size.height))
    }
    #endif
}

extension AppSettings {
    /// What streams on this device are held to: the streaming quality, what an Apple TV's output
    /// makes use of, and with Adaptive Quality, the bitrate the connection was learned to carry.
    var streamingLimit: StreamingLimit {
        StreamingLimit(quality: streamingQuality, displayHeight: DisplayOutput.streamingHeight,
                       bitrate: adaptiveQuality ? learnedQuality.limit : nil)
    }
}
