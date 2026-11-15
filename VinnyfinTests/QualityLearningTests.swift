import Foundation
import Testing
@testable import vinnyfin

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Eight in the evening on the first day.
private let firstEvening = utc.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 20))!

/// A rebuffer `day` days after the first evening, `hours` past eight.
private func incident(day: Int, hours: Double = 0, bitrate: Int = 40_000_000, title: String = "a") -> QualityLearning.Incident {
    QualityLearning.Incident(date: firstEvening.addingTimeInterval((Double(day) * 24 + hours) * 60 * 60),
                             bitrate: bitrate, resolution: 2160, title: title)
}

private extension QualityLearning {
    /// Takes each in turn; the last limit they taught.
    @discardableResult
    mutating func recordAll(_ incidents: [Incident]) -> Int? {
        var learned: Int?
        for incident in incidents {
            learned = record(incident, calendar: utc) ?? learned
        }
        return learned
    }
}

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

struct QualityLearningTests {
    @Test func learnsOnceStreamsKeepRebufferingOnSeparateDaysInDifferentTitles() {
        var learning = QualityLearning()
        #expect(learning.recordAll([incident(day: 0, title: "a"), incident(day: 1, title: "b")]) == nil)
        #expect(learning.limit == nil)
        // A step below 40 Mbps.
        #expect(learning.record(incident(day: 2, title: "a"), calendar: utc) == 28_000_000)
        #expect(learning.limit == 28_000_000)
    }

    @Test func oneBadEveningTeachesNothing() {
        // Every half hour from eight in the evening to half past one in the morning, in four titles.
        var learning = QualityLearning()
        let evening = (0..<12).map { incident(day: 0, hours: Double($0) / 2, title: ["a", "b", "c", "d"][$0 % 4]) }
        #expect(learning.recordAll(evening) == nil)
        // A second evening still isn't enough.
        #expect(learning.recordAll([incident(day: 1, title: "a"), incident(day: 1, hours: 2, title: "b")]) == nil)
        #expect(learning.limit == nil)
    }

    @Test func aDayRunsFromFiveInTheMorning() {
        let lateEvening = QualityLearning.day(of: incident(day: 0, hours: 3).date, calendar: utc)
        let smallHours = QualityLearning.day(of: incident(day: 0, hours: 8.9).date, calendar: utc)
        let nextMorning = QualityLearning.day(of: incident(day: 0, hours: 9.1).date, calendar: utc)
        #expect(lateEvening == smallHours)
        #expect(nextMorning > smallHours)
    }

    @Test func oneFlakyTitleTeachesNothing() {
        var learning = QualityLearning()
        #expect(learning.recordAll((0..<10).map { incident(day: $0, title: "flaky") }) == nil)
        // Another title rebuffering at the same bitrate shows it's the connection.
        #expect(learning.record(incident(day: 10, title: "other"), calendar: utc) == 28_000_000)
    }

    @Test func forgetsIncidentsOlderThanTheWindow() {
        var learning = QualityLearning()
        #expect(learning.recordAll([incident(day: 0, title: "a"), incident(day: 15, title: "b")]) == nil)
        // 31 days after the first, it no longer counts.
        #expect(learning.record(incident(day: 31, title: "a"), calendar: utc) == nil)
        #expect(learning.incidents.count == 2)
        #expect(learning.record(incident(day: 32, title: "b"), calendar: utc) == 28_000_000)

        // Within 30 days of the first, it does.
        var withinWindow = QualityLearning()
        #expect(withinWindow.recordAll([incident(day: 0, title: "a"), incident(day: 15, title: "b"), incident(day: 30, title: "a")])
            == 28_000_000)
    }

    @Test func aStreamFarBelowTheRestCantDragTheLimitDown() {
        var learning = QualityLearning()
        // 4K remuxes rebuffered on two evenings, a 1080p stream once on another.
        #expect(learning.recordAll([
            incident(day: 0, bitrate: 60_000_000, title: "a"),
            incident(day: 1, bitrate: 8_000_000, title: "c"),
            incident(day: 2, bitrate: 50_000_000, title: "b"),
        ]) == nil)
        // A third evening of 4K trouble: a step below the lowest of it, 42 Mbps.
        #expect(learning.record(incident(day: 3, bitrate: 42_000_000, title: "a"), calendar: utc) == 29_000_000)
    }

    @Test func aFlakyTitleFarBelowTheRestCantSetTheLimit() {
        var learning = QualityLearning()
        #expect(learning.recordAll([
            incident(day: 0, bitrate: 8_000_000, title: "flaky"),
            incident(day: 1, bitrate: 8_000_000, title: "flaky"),
            incident(day: 2, bitrate: 60_000_000, title: "b"),
        ]) == nil)
    }

    @Test func takesTroubleAtDifferentBitratesTogether() {
        var learning = QualityLearning()
        let learned = learning.recordAll([
            incident(day: 0, bitrate: 70_000_000, title: "a"),
            incident(day: 1, bitrate: 55_000_000, title: "b"),
            incident(day: 3, bitrate: 80_000_000, title: "c"),
        ])
        #expect(learned == 38_000_000)
    }

    @Test func stepsFurtherDownFromTroubleWithinTheLimit() {
        var learning = QualityLearning()
        learning.recordAll([incident(day: 0, title: "a"), incident(day: 1, title: "b"), incident(day: 2, title: "a")])
        #expect(learning.limit == 28_000_000)
        // A version picked above the limit says nothing about streams within it.
        #expect(learning.record(incident(day: 3, bitrate: 35_000_000, title: "c"), calendar: utc) == nil)
        #expect(learning.incidents.isEmpty)
        #expect(learning.recordAll([
            incident(day: 4, bitrate: 25_000_000, title: "a"),
            incident(day: 5, bitrate: 25_000_000, title: "b"),
        ]) == nil)
        #expect(learning.record(incident(day: 6, bitrate: 25_000_000, title: "a"), calendar: utc) == 17_000_000)
        #expect(learning.limit == 17_000_000)
    }

    @Test func neverGoesBelowTheSmallestTranscode() {
        var learning = QualityLearning()
        let slow = (0..<3).map { incident(day: $0, bitrate: 3_000_000, title: ["a", "b", "c"][$0]) }
        #expect(learning.recordAll(slow) == VideoQuality.sd.transcodeBitrate)
        let slower = (3..<6).map { incident(day: $0, bitrate: 2_000_000, title: ["a", "b", "c"][$0 - 3]) }
        #expect(learning.recordAll(slower) == nil)
        #expect(learning.limit == VideoQuality.sd.transcodeBitrate)
    }

    @Test func resetForgetsEverything() {
        var learning = QualityLearning()
        learning.recordAll([incident(day: 0, title: "a"), incident(day: 1, title: "b"), incident(day: 2, title: "a")])
        learning.record(incident(day: 3, bitrate: 20_000_000, title: "b"), calendar: utc)
        learning.reset()
        #expect(learning == QualityLearning())
        // What came before the reset doesn't count toward the next limit.
        #expect(learning.recordAll([incident(day: 4, title: "a"), incident(day: 5, title: "b")]) == nil)
    }

    @Test func namesTheLimitInMegabits() {
        #expect(QualityLearning.label(forBitrate: 20_000_000) == "20 Mbps")
        #expect(QualityLearning.label(forBitrate: 28_000_000) == "28 Mbps")
        #expect(QualityLearning.label(forBitrate: 2_500_000) == "2.5 Mbps")
        #expect(QualityLearning.label(forBitrate: 350_400) == "350 kbps")
    }
}

struct RebufferIncidentTests {
    let movie = JellyfinItem(id: "m1", name: "Movie", type: "Movie")
    let uhd = version("4k", "2160p", height: 2160, bitrate: 40_000_000)
    /// The buffer ran dry and the link wasn't measured.
    let drained = ConnectionWatch.Sample(time: 100, isWanted: true, position: 600, bufferedAhead: 2, bitrate: 40_000_000)

    private func incident(_ reason: ConnectionWatch.Reason = .stalled, plan: PlaybackPlan? = nil, item: JellyfinItem? = nil,
                          sample: ConnectionWatch.Sample? = nil, throughput: Double? = nil,
                          expensive: Bool = false) -> QualityLearning.Incident? {
        QualityLearning.Incident(reason, playing: plan ?? .direct(uhd), of: item ?? movie, sample: sample ?? drained,
                                 throughput: throughput, isExpensiveNetwork: expensive, date: firstEvening)
    }

    @Test func countsAFreezeOnceTheBufferRanDry() {
        #expect(incident(.stalled) == QualityLearning.Incident(date: firstEvening, bitrate: 40_000_000, resolution: 2160, title: "m1"))
        #expect(incident(.stuttering) != nil)
    }

    @Test func countsALinkMeasuredFallingBehind() {
        #expect(incident(.fallingBehind, throughput: 20_000_000)?.bitrate == 40_000_000)
    }

    @Test func leavesOutASlowStart() {
        // Opening the file, or the server getting going, as after a seek.
        #expect(incident(.slowStart) == nil)
    }

    @Test func leavesOutATranscode() {
        // The server may be what's behind.
        #expect(incident(.stalled, plan: .transcode(uhd, .fullHD)) == nil)
        #expect(incident(.fallingBehind, plan: .transcode(uhd, .fullHD), throughput: 5_000_000) == nil)
    }

    @Test func leavesOutARemoteStream() {
        var remote = version("remote", "[Remote] 4K", bitrate: 40_000_000)
        remote.isRemote = true
        #expect(incident(.stalled, plan: .direct(remote)) == nil)
    }

    @Test func leavesOutCellularAndHotspots() {
        #expect(incident(.stalled, expensive: true) == nil)
    }

    @Test func leavesOutAFreezeWithTheStreamAtHand() {
        var buffered = drained
        buffered.bufferedAhead = 30
        #expect(incident(.stalled, sample: buffered) == nil)
    }

    @Test func leavesOutAFreezeTheLinkCarried() {
        #expect(incident(.stalled, throughput: 60_000_000) == nil)
        #expect(incident(.stalled, throughput: 20_000_000) != nil)
    }

    @Test func weighsTheBitrateByTheSpeed() {
        var doubleSpeed = drained
        doubleSpeed.rate = 2
        #expect(incident(.stalled, sample: doubleSpeed)?.bitrate == 80_000_000)
        #expect(incident(.stalled, sample: doubleSpeed, throughput: 60_000_000) != nil)
    }

    @Test func goesByTheMeasuredBitrateWhenTheServerHasNone() {
        let unmeasured = version("unmeasured", "1080p", height: 1080)
        var sample = drained
        sample.bitrate = 12_000_000
        #expect(incident(.stalled, plan: .direct(unmeasured), sample: sample)?.bitrate == 12_000_000)
    }

    @Test func countsAShowsEpisodesAsOneTitle() {
        var pilot = JellyfinItem(id: "e1", name: "Pilot", type: "Episode")
        pilot.seriesId = "show"
        var finale = JellyfinItem(id: "e9", name: "Finale", type: "Episode")
        finale.seriesId = "show"
        #expect(incident(item: pilot)?.title == "show")
        #expect(incident(item: finale)?.title == "show")
    }
}

struct LearnedQualityStorageTests {
    /// iCloud's key-value store as a dictionary, recording what's written to it.
    private final class Cloud: CloudKeyValues {
        var values: [String: Any] = [:]
        private(set) var writes: [String] = []
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) {
            values[key] = value
            writes.append(key)
        }
        func removeObject(forKey key: String) {
            values[key] = nil
            writes.append(key)
        }
        var dictionaryRepresentation: [String: Any] { values }
    }

    @Test func keepsWhatItLearnedOnThisDeviceAlone() {
        let name = "quality-learning-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = Cloud()
        let settings = AppSettings(defaults: defaults, cloud: cloud)
        settings.learnedQuality.recordAll([incident(day: 0, title: "a"), incident(day: 1, title: "b"), incident(day: 2, title: "a")])
        settings.reconcileWithCloud()
        #expect(cloud.writes.isEmpty)
        #expect(!AppSettings.syncs("settings.learnedQuality"))
        // It's there after a relaunch, until it's reset.
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.learnedQuality == settings.learnedQuality)
        #expect(relaunched.learnedQuality.limit == 28_000_000)
        relaunched.learnedQuality.reset()
        #expect(AppSettings(defaults: defaults).learnedQuality.limit == nil)
    }

    @Test func holdsStreamsToWhatWasLearnedWhileAdaptiveQualityIsOn() {
        let name = "quality-learning-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.streamingLimit.bitrate == nil)
        settings.learnedQuality.recordAll([incident(day: 0, title: "a"), incident(day: 1, title: "b"), incident(day: 2, title: "a")])
        #expect(settings.streamingLimit.bitrate == 28_000_000)
        settings.adaptiveQuality = false
        #expect(settings.streamingLimit.bitrate == nil)
        #expect(settings.learnedQuality.limit == 28_000_000)
    }
}
