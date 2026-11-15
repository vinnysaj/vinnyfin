import AetherEngine
import CoreGraphics
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

private let uhd = version("2160", "2160p", height: 2160, bitrate: 25_259_033)
private let fullHD = version("1080", "1080p", height: 1080, bitrate: 8_261_500)
private let hd = version("720", "720p", height: 720, bitrate: 3_262_945)
private let all = [uhd, fullHD, hd]

struct StepUpTests {
    private func stepUp(from plan: PlaybackPlan, toward ceiling: PlaybackPlan = .direct(uhd), throughput: Int,
                        sources: [MediaSource] = all, allowTranscoding: Bool = true) -> PlaybackPlan? {
        VersionChooser.planStepUp(from: plan, toward: ceiling, throughput: throughput, sources: sources, allowTranscoding: allowTranscoding)
    }

    @Test func goesBackToTheOriginalOnceTheLinkCarriesItWithRoomToSpare() {
        #expect(stepUp(from: .transcode(uhd, .hd), throughput: 50_000_000) == .direct(uhd))
        // 25 Mbps carried by a link of 30 is too close: a dip would bring it back down.
        #expect(stepUp(from: .transcode(uhd, .hd), throughput: 30_000_000) != .direct(uhd))
    }

    @Test func takesTheBestStepTheLinkCarries() {
        #expect(stepUp(from: .transcode(uhd, .hd), throughput: 20_000_000) == .direct(fullHD))
    }

    @Test func prefersAVersionToAConversionTheSameSize() {
        // A 1080p conversion at 16 Mbps fits as well; the 1080p file as it is is better.
        #expect(stepUp(from: .transcode(uhd, .sd), throughput: 30_000_000) == .direct(fullHD))
    }

    @Test func staysWhenNothingDearerFits() {
        #expect(stepUp(from: .transcode(uhd, .hd), throughput: 8_000_000) == nil)
    }

    @Test func neverGoesPastTheWayTheTitleStarted() {
        #expect(stepUp(from: .direct(hd), toward: .direct(fullHD), throughput: 100_000_000) == .direct(fullHD))
        #expect(stepUp(from: .direct(fullHD), toward: .direct(fullHD), throughput: 100_000_000) == nil)
        #expect(stepUp(from: .transcode(uhd, .sd), toward: .transcode(uhd, .hd), throughput: 100_000_000) == .transcode(uhd, .hd))
    }

    @Test func leavesOutConversionsWhenTranscodingIsOff() {
        #expect(stepUp(from: .direct(hd), throughput: 20_000_000, allowTranscoding: false) == .direct(fullHD))
        #expect(stepUp(from: .direct(hd), throughput: 11_000_000, sources: [uhd, hd], allowTranscoding: false) == nil)
    }
}

/// Samples a second apart through a recovery watch.
private struct Recovery {
    var watch: RecoveryWatch
    var time: Double = 0
    var position: Double = 600
    var throughput: Double? = 40_000_000
    var isWanted = true

    init(failedStepUps: Int = 0) {
        watch = RecoveryWatch(failedStepUps: failedStepUps)
    }

    mutating func run(_ seconds: Int, advance: Double = 1) {
        for _ in 0..<seconds {
            time += 1
            position += advance
            watch.observe(ConnectionWatch.Sample(time: time, isWanted: isWanted, position: position, throughput: throughput))
        }
    }
}

struct RecoveryWatchTests {
    @Test func saysNothingUntilTheStreamHasSettled() {
        var recovery = Recovery()
        recovery.run(Int(RecoveryWatch.settle) - 5)
        #expect(recovery.watch.heldThroughput == nil)
        recovery.run(10)
        #expect(recovery.watch.heldThroughput == 40_000_000)
    }

    @Test func takesTheLeastTheLinkHeldOverTheMinute() {
        var recovery = Recovery()
        recovery.run(100)
        recovery.throughput = 15_000_000
        recovery.run(30)
        #expect(recovery.watch.heldThroughput == 15_000_000)
    }

    @Test func aMomentsDipDoesntCount() {
        var recovery = Recovery()
        recovery.run(130)
        // One low reading is outdone by the best of the ten seconds around it.
        recovery.throughput = 2_000_000
        recovery.run(1)
        recovery.throughput = 40_000_000
        recovery.run(1)
        #expect(recovery.watch.heldThroughput == 40_000_000)
    }

    @Test func aFreezeStartsItOver() {
        var recovery = Recovery()
        recovery.run(130)
        recovery.run(3, advance: 0)
        #expect(recovery.watch.heldThroughput == nil)
        recovery.run(Int(RecoveryWatch.settle) + 1)
        #expect(recovery.watch.heldThroughput == 40_000_000)
    }

    @Test func aPauseNeitherCountsNorStartsItOver() {
        var recovery = Recovery()
        recovery.run(100)
        let steady = recovery.watch.steady
        recovery.isWanted = false
        recovery.run(300, advance: 0)
        #expect(recovery.watch.steady == steady)
        #expect(recovery.watch.heldThroughput == nil)
        // The link is measured afresh after a pause: what it held before it is old news.
        recovery.isWanted = true
        recovery.run(30)
        #expect(recovery.watch.heldThroughput == nil)
        recovery.run(31)
        #expect(recovery.watch.heldThroughput == 40_000_000)
    }

    @Test func waitsTwiceAsLongAfterEachStepUpThatDidntHold() {
        #expect(RecoveryWatch.settle(afterFailedStepUps: 1) == 2 * RecoveryWatch.settle)
        var recovery = Recovery(failedStepUps: 1)
        recovery.run(Int(RecoveryWatch.settle) + 10)
        #expect(recovery.watch.heldThroughput == nil)
        recovery.run(Int(RecoveryWatch.settle))
        #expect(recovery.watch.heldThroughput != nil)
    }

    @Test func switchesWhilePausedOrAtAChapter() {
        var recovery = Recovery()
        recovery.run(130)
        let chapters = [0, 300, 900.0]
        #expect(recovery.watch.isMoment(isPaused: true, from: 700, to: 700, chapters: chapters))
        #expect(recovery.watch.isMoment(isPaused: false, from: 899.5, to: 900.5, chapters: chapters))
        #expect(!recovery.watch.isMoment(isPaused: false, from: 700, to: 701, chapters: chapters))
        // A jump over a chapter is a seek, not playback reaching it.
        #expect(!recovery.watch.isMoment(isPaused: false, from: 100, to: 400, chapters: chapters))
    }

    @Test func aTitleWithoutChaptersSwitchesOnceItHasHeldLonger() {
        var recovery = Recovery()
        recovery.run(130)
        #expect(!recovery.watch.isMoment(isPaused: false, from: 700, to: 701, chapters: []))
        recovery.run(Int(RecoveryWatch.chapterlessWait))
        #expect(recovery.watch.isMoment(isPaused: false, from: 700, to: 701, chapters: []))
    }
}

struct PictureWatchTests {
    @Test func saysOnceTheSoundHasPlayedAloneLongEnough() {
        var watch = PictureWatch()
        var said: [Int] = []
        for second in 1...20 where watch.observe(clock: 600 + Double(second), isRunning: true, hasPicture: false) {
            said.append(second)
        }
        #expect(said == [Int(PictureWatch.soundAlone) + 1])
    }

    @Test func leavesAStreamWithAPictureAlone() {
        var watch = PictureWatch()
        var said = false
        for second in 1...20 where watch.observe(clock: Double(second), isRunning: true, hasPicture: true) {
            said = true
        }
        #expect(!said)
    }

    @Test func countsNeitherTheJumpToTheStartNorAPause() {
        var watch = PictureWatch()
        // The engine seeks to the start position, plays 5 seconds, pauses, and plays on.
        let clocks: [(Double, Bool)] = [(0, true), (1_800, true)] + (1...5).map { (1_800 + Double($0), true) }
            + Array(repeating: (1_805, false), count: 25) + (6...9).map { (1_800 + Double($0), true) }
        let said = clocks.map { clock, running in watch.observe(clock: clock, isRunning: running, hasPicture: false) }
        #expect(said.firstIndex(of: true) == clocks.count - 1)
    }

    @Test func offersTheNextSmallerVersionElseTheServer() {
        let limit = StreamingLimit(quality: .original)
        #expect(VersionChooser.lighter(than: .direct(uhd), sources: all, limit: limit) == .direct(fullHD))
        #expect(VersionChooser.lighter(than: .direct(hd), sources: all, limit: limit) == .transcode(hd, .fullHD))
        #expect(VersionChooser.lighter(than: .direct(uhd), sources: [uhd], limit: StreamingLimit(quality: .hd)) == .transcode(uhd, .hd))
        #expect(VersionChooser.lighter(than: .transcode(uhd, .hd), sources: all, limit: limit) == nil)
        #expect(PictureOffer(plan: .direct(fullHD)).action == "Play 1080p")
        #expect(PictureOffer(plan: .transcode(hd, .fullHD)).action == "Play Through the Server")
    }
}

struct TranscodeReconnectTests {
    private let lost = PlaybackErrorInfo(kind: .sourceRefused, message: "404", underlyingCode: 404)

    /// Whether `reconnect` reconnects after `info`, of a transcode that showed its picture unless said otherwise.
    private func reconnects(_ reconnect: inout TranscodeReconnect, after info: PlaybackErrorInfo? = nil,
                            isTranscode: Bool = true, hadPicture: Bool = true) -> Bool {
        reconnect.shouldReconnect(after: info ?? lost, isTranscode: isTranscode, hadPicture: hadPicture)
    }

    @Test func reconnectsATranscodeTheServerLost() {
        var reconnect = TranscodeReconnect()
        let did = reconnects(&reconnect)
        #expect(did)
        #expect(reconnect.playedSinceReconnect == 0)
    }

    @Test func triesOnceUntilTheReconnectedStreamHasPlayedAMinute() {
        var reconnect = TranscodeReconnect()
        let first = reconnects(&reconnect)
        reconnect.played(TranscodeReconnect.playsBeforeAnother - 1)
        let tooSoon = reconnects(&reconnect)
        reconnect.played(1)
        let again = reconnects(&reconnect)
        #expect(first && !tooSoon && again)
    }

    @Test func leavesAFileAsItIsToTheEngine() {
        var reconnect = TranscodeReconnect()
        let did = reconnects(&reconnect, isTranscode: false)
        #expect(!did)
    }

    @Test func leavesAStreamThatNeverStartedFailed() {
        var reconnect = TranscodeReconnect()
        let did = reconnects(&reconnect, hadPicture: false)
        #expect(!did)
    }

    @Test func leavesFailuresAFreshTranscodeWontGetPast() {
        let refusals: [PlaybackErrorInfo] = [
            PlaybackErrorInfo(kind: .sourceRefused, message: "", underlyingCode: 401),
            PlaybackErrorInfo(kind: .sourceRefused, message: "", underlyingCode: 403),
            PlaybackErrorInfo(kind: .sourceCertificateRejected, message: ""),
            PlaybackErrorInfo(kind: .storageExhausted, message: ""),
        ]
        for info in refusals {
            var reconnect = TranscodeReconnect()
            let did = reconnects(&reconnect, after: info)
            #expect(!did, "\(info.kind)")
        }
        #expect(TranscodeReconnect.mayRecover(from: PlaybackErrorInfo(kind: .vodSourceFailed, message: "")))
        #expect(TranscodeReconnect.mayRecover(from: nil))
    }
}

struct QualityPanelTests {
    private func summary(_ plan: PlaybackPlan, _ reason: QualityReason, sources: [MediaSource] = all) -> String {
        QualityStatus(plan: plan, reason: reason, sources: sources).summary
    }

    @Test func saysWhatPlays() {
        #expect(summary(.direct(uhd), .streamingLimit(nil)) == "Original · 4K")
        #expect(summary(.direct(hd), .streamingLimit(nil), sources: [hd]) == "Original · 720p")
        #expect(summary(.direct(fullHD), .picked) == "1080p version, as you chose")
        #expect(summary(.transcode(uhd, .hd), .picked) == "Converted to 720p, as you chose")
    }

    @Test func saysWhy() {
        #expect(summary(.transcode(uhd, .hd), .connectionSlowed) == "Converted to 720p, the connection slowed")
        #expect(summary(.direct(fullHD), .connectionSlowed) == "1080p version, the connection slowed")
        #expect(summary(.direct(uhd), .connectionRecovered) == "Original · 4K, the connection recovered")
        #expect(summary(.direct(fullHD), .streamingLimit(.setting(.fullHD))) == "1080p version, Streaming Quality is set to 1080p")
        #expect(summary(.direct(fullHD), .streamingLimit(.display(1080))) == "1080p version, this TV shows 1080p")
        #if os(macOS)
        #expect(summary(.transcode(uhd, .hd), .streamingLimit(.network(.expensive))) == "Converted to 720p, on a Personal Hotspot")
        #else
        #expect(summary(.transcode(uhd, .hd), .streamingLimit(.network(.expensive))) == "Converted to 720p, on cellular data")
        #endif
        #expect(summary(.transcode(uhd, .hd), .streamingLimit(.network(.lowData))) == "Converted to 720p, in Low Data Mode")
        #expect(summary(.direct(fullHD), .streamingLimit(.learnedBitrate(12_000_000)))
            == "1080p version, the connection here carries about 12 Mbps")
        #expect(summary(.transcode(uhd, .fullHD), .deviceCouldNotPlay) == "Converted to 1080p, this device can't play the original")
        #expect(summary(.direct(hd), .pickedOnPage) == "720p version, picked on the title's page")
    }

    @Test func detailsTheStream() {
        #expect(QualityStatus(plan: .transcode(uhd, .hd), reason: .connectionSlowed, sources: all).detail == "From 4K · up to 6 Mbps")
        #expect(QualityStatus(plan: .direct(fullHD), reason: .picked, sources: all).detail == "8.3 Mbps")
    }

    @Test func findsWhatHeldTheTitleBackAsItStarted() {
        func started(_ plan: PlaybackPlan, pickedOnPage: Bool = false, _ limit: StreamingLimit) -> QualityReason {
            .started(plan, sources: all, pickedOnPage: pickedOnPage, limit: limit)
        }
        #expect(started(.direct(uhd), StreamingLimit(quality: .original)) == .streamingLimit(nil))
        #expect(started(.direct(fullHD), StreamingLimit(quality: .fullHD)) == .streamingLimit(.setting(.fullHD)))
        // Held to the cellular streaming quality, below the streaming quality.
        #expect(started(.direct(hd), StreamingLimit(quality: .hd, savingData: .expensive)) == .streamingLimit(.network(.expensive)))
        #expect(started(.direct(fullHD), StreamingLimit(quality: .original, displayHeight: 1080)) == .streamingLimit(.display(1080)))
        #expect(started(.direct(fullHD), StreamingLimit(quality: .original, bitrate: 12_000_000))
            == .streamingLimit(.learnedBitrate(12_000_000)))
        #expect(started(.direct(hd), pickedOnPage: true, StreamingLimit(quality: .original)) == .pickedOnPage)
        // A version picked on the page that's over the limit is converted, for the limit.
        #expect(started(.transcode(uhd, .hd), pickedOnPage: true, StreamingLimit(quality: .hd)) == .streamingLimit(.setting(.hd)))
    }

    @Test func offersAutoTheVersionsAndTheSizesThatSaveSomething() {
        #expect(QualityOption.all(sources: all, playing: uhd)
            == [.auto, .version(uhd), .version(fullHD), .version(hd), .converted(.fullHD), .converted(.hd), .converted(.sd)])
        // A 32 Mbps 1080p remux is worth converting at its own size.
        let remux = version("remux", "1080p REMUX", height: 1080, bitrate: 32_000_000)
        #expect(QualityOption.all(sources: [remux], playing: remux) == [.auto, .version(remux), .converted(.fullHD), .converted(.hd), .converted(.sd)])
        var unconvertible = hd
        unconvertible.supportsTranscoding = false
        #expect(QualityOption.all(sources: [unconvertible], playing: unconvertible) == [.auto, .version(unconvertible)])
    }
}

struct EpisodesPanelTests {
    private func episodes(_ ids: [String]) -> [JellyfinItem] {
        ids.map { JellyfinItem(id: $0, name: "Episode \($0)", type: "Episode") }
    }

    @Test func takesASheetUprightAndARowOtherwise() {
        #expect(EpisodesLayout.form(isCompactWidth: true, isCompactHeight: false, isShortBand: false) == .sheet)
        #expect(EpisodesLayout.form(isCompactWidth: true, isCompactHeight: true, isShortBand: true) == .rail)
        #expect(EpisodesLayout.form(isCompactWidth: false, isCompactHeight: true, isShortBand: true) == .rail)
        #expect(EpisodesLayout.form(isCompactWidth: false, isCompactHeight: false, isShortBand: false) == .drawer)
    }

    @Test func fillsTheScreenBelowThePicture() {
        let phone = CGSize(width: 402, height: 874)
        // A 16:9 picture 226 points tall leaves 323 below it.
        #expect(EpisodesLayout.sheetHeight(screen: phone, videoSize: nil) == 323)
        #expect(EpisodesLayout.sheetHeight(screen: phone, videoSize: CGSize(width: 1920, height: 800)) == 353)
        // A picture nearly as tall as the screen still leaves room for a few episodes.
        #expect(EpisodesLayout.sheetHeight(screen: phone, videoSize: CGSize(width: 1080, height: 1920)) == EpisodesLayout.minimumSheet)
    }

    @Test func bringsThePlayingEpisodeIntoView() {
        let playing = JellyfinItem(id: "e3", name: "Episode 3", type: "Episode")
        #expect(EpisodesLayout.inView(among: episodes(["e1", "e2", "e3", "e4"]), playing: playing) == "e3")
        // Another season's start.
        #expect(EpisodesLayout.inView(among: episodes(["f1", "f2"]), playing: playing) == "f1")
        #expect(EpisodesLayout.inView(among: [], playing: playing) == nil)
    }
}
