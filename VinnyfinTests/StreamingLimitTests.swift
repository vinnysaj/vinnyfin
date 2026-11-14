import Foundation
import Testing
@testable import vinnyfin

private func version(_ id: String, _ name: String? = nil, height: Int? = nil, bitrate: Int? = nil) -> MediaSource {
    var source = MediaSource(id: id, name: name)
    source.bitrate = bitrate
    if let height {
        var video = MediaStream(type: "Video")
        video.width = height * 16 / 9
        video.height = height
        source.mediaStreams = [video]
    }
    return source
}

struct StreamingLimitTests {
    let remux = version("4k-remux", "2160p REMUX", height: 2160, bitrate: 70_000_000)
    let web4K = version("4k-web", "2160p WEB-DL", height: 2160, bitrate: 25_000_000)
    let fullHD = version("1080", "1080p", height: 1080, bitrate: 10_000_000)
    let hd = version("720", "720p", height: 720, bitrate: 4_000_000)

    /// On an Apple TV outputting 1080p.
    private func onTV1080p(_ quality: VideoQuality) -> StreamingLimit {
        StreamingLimit(quality: quality, displayHeight: 1080)
    }

    @Test func anOutputOf1080pOrLessMakesUseOfNoMoreThan1080p() {
        #expect(DisplayOutput.streamingHeight(forOutputHeight: 1080) == 1080)
        #expect(DisplayOutput.streamingHeight(forOutputHeight: 720) == 1080)
        #expect(DisplayOutput.streamingHeight(forOutputHeight: 2160) == nil)
        #expect(DisplayOutput.streamingHeight(forOutputHeight: nil) == nil)
    }

    @Test func aTVOutputting1080pNeverGetsA4KVersion() {
        let sources = [remux, web4K, fullHD, hd]
        #expect(VersionChooser.choose(from: sources, limit: onTV1080p(.original))?.id == "1080")
        #expect(VersionChooser.choose(from: sources, limit: onTV1080p(.uhd))?.id == "1080")
        #expect(VersionChooser.choose(from: sources, limit: onTV1080p(.hd))?.id == "720")
        // Elsewhere, Best Available is the item's own version.
        #expect(VersionChooser.choose(from: sources, limit: StreamingLimit(quality: .original))?.id == "4k-remux")
    }

    @Test func aTVOutputting1080pHasA4KOnlyTitleScaledTo1080p() {
        #expect(VersionChooser.planStreaming(sources: [remux], preferred: nil, limit: onTV1080p(.original), allowTranscoding: true)
            == .transcode(remux, .fullHD))
        #expect(VersionChooser.planStreaming(sources: [remux], preferred: nil, limit: onTV1080p(.original), allowTranscoding: false)
            == .direct(remux))
        // A 4K version picked on the page is scaled down too, as with a streaming quality of 1080p.
        #expect(VersionChooser.planStreaming(sources: [remux, fullHD], preferred: remux, limit: onTV1080p(.uhd), allowTranscoding: true)
            == .transcode(remux, .fullHD))
    }

    @Test func aTVOutputting1080pTranscodesTo1080pAtMost() {
        #expect(onTV1080p(.original).transcodeQuality == .fullHD)
        #expect(onTV1080p(.uhd).transcodeQuality == .fullHD)
        #expect(onTV1080p(.hd).transcodeQuality == .hd)
        #expect(StreamingLimit(quality: .uhd).transcodeQuality == .uhd)
        #expect(StreamingLimit(quality: .original).transcodeQuality == nil)
    }

    @Test func aLearnedBitrateTakesTheBestVersionWithinIt() {
        let limit = StreamingLimit(quality: .original, bitrate: 49_000_000)
        #expect(VersionChooser.choose(from: [remux, web4K, fullHD], limit: limit)?.id == "4k-web")
        // The item's own version stays first while it's within it.
        #expect(VersionChooser.choose(from: [fullHD, web4K], limit: limit)?.id == "1080")
        let fullHDRemux = version("1080-remux", "1080p REMUX", height: 1080, bitrate: 30_000_000)
        #expect(VersionChooser.choose(from: [fullHDRemux, fullHD], limit: StreamingLimit(quality: .fullHD, bitrate: 20_000_000))?.id
            == "1080")
    }

    @Test func aLearnedBitrateHasTheServerTranscodeBelowIt() {
        let limit = StreamingLimit(quality: .original, bitrate: 49_000_000)
        #expect(VersionChooser.planStreaming(sources: [remux], preferred: nil, limit: limit, allowTranscoding: true) == .transcode(remux, .fullHD))
        #expect(VersionChooser.planStreaming(sources: [remux], preferred: nil, limit: limit, allowTranscoding: false) == .direct(remux))
        #expect(StreamingLimit(quality: .original, bitrate: 10_000_000).transcodeQuality == .hd)
        #expect(StreamingLimit(quality: .original, bitrate: 1_000_000).transcodeQuality == .sd)
    }

    @Test func overALearnedBitrateTakesTheLowestOne() {
        let remux1080 = version("1080-remux", "1080p REMUX", height: 1080, bitrate: 30_000_000)
        let web1080 = version("1080-web", "1080p WEB-DL", height: 1080, bitrate: 22_000_000)
        let limit = StreamingLimit(quality: .original, bitrate: 20_000_000)
        #expect(VersionChooser.choose(from: [remux, remux1080, web1080], limit: limit)?.id == "1080-web")
        #expect(VersionChooser.planStreaming(sources: [remux, remux1080, web1080], preferred: nil, limit: limit, allowTranscoding: true)
            == .transcode(web1080, .fullHD))
    }

    @Test func triesAStreamOfUnknownBitrateBeforeScalingDown() {
        let remote = version("remote", "[Remote] 4K HDR")
        let limit = StreamingLimit(quality: .original, bitrate: 49_000_000)
        #expect(VersionChooser.choose(from: [remux, remote], limit: limit)?.id == "remote")
        #expect(VersionChooser.planStreaming(sources: [remote], preferred: nil, limit: limit, allowTranscoding: true) == .direct(remote))
    }
}
