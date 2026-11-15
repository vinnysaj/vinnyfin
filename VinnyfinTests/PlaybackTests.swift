import AetherEngine
import AVFoundation
import Foundation
import Testing
@testable import vinnyfin

/// AetherEngine has a `MediaSource` of its own.
typealias MediaSource = vinnyfin.MediaSource

private func version(_ id: String, _ name: String? = nil, width: Int? = nil, height: Int? = nil) -> MediaSource {
    var source = MediaSource(id: id, name: name)
    if let width, let height {
        var video = MediaStream(type: "Video")
        video.width = width
        video.height = height
        source.mediaStreams = [video]
    }
    return source
}

struct VersionChooserTests {
    let versions = [
        version("4k-remux", "2160p REMUX", width: 3840, height: 2160),
        version("1080-web", "1080p WEB-DL", width: 1920, height: 1080),
        version("1080-bluray", "1080p BluRay", width: 1920, height: 1080),
        version("720", "720p", width: 1280, height: 720),
    ]

    @Test func bestAvailableTakesTheServersFirst() {
        #expect(VersionChooser.choose(from: versions, quality: .original)?.id == "4k-remux")
    }

    @Test func takesTheBestThatFitsKeepingTheServersOrder() {
        #expect(VersionChooser.choose(from: versions, quality: .fullHD)?.id == "1080-web")
        #expect(VersionChooser.choose(from: versions, quality: .hd)?.id == "720")
        #expect(VersionChooser.choose(from: versions, quality: .uhd)?.id == "4k-remux")
    }

    @Test func triesAnUnlabelledVersionBeforeScalingDown() {
        let sources = [version("4k", "2160p", width: 3840, height: 2160), version("mystery", "Main")]
        #expect(VersionChooser.choose(from: sources, quality: .fullHD)?.id == "mystery")
    }

    @Test func takesTheSmallestWhenNothingFits() {
        let sources = [version("4k", width: 3840, height: 2160), version("1080", width: 1920, height: 1080)]
        #expect(VersionChooser.choose(from: sources, quality: .hd)?.id == "1080")
    }

    @Test func readsTheClassFromWideFramesAndNames() {
        #expect(VersionTraits(version("scope", width: 1920, height: 800)).resolutionClass == 1080)
        #expect(VersionTraits(version("cropped", width: 3840, height: 1606)).resolutionClass == 2160)
        #expect(VersionTraits(version("remote", "[Remote] 4K HDR DV")).resolutionClass == 2160)
        #expect(VersionTraits(version("named", "Movie.1080p.WEB")).resolutionClass == 1080)
        #expect(VersionTraits(version("none", "Director's Cut")).resolutionClass == nil)
    }

    @Test func streamsTheOriginalWhenItFits() {
        let plan = VersionChooser.planStreaming(sources: versions, preferred: nil, limit: StreamingLimit(quality: .fullHD), allowTranscoding: true)
        #expect(plan == .direct(versions[1]))
    }

    @Test func scalesDownAPickedVersionThatIsTooBig() {
        let plan = VersionChooser.planStreaming(sources: versions, preferred: versions[0], limit: StreamingLimit(quality: .fullHD), allowTranscoding: true)
        #expect(plan == .transcode(versions[0], .fullHD))
    }

    @Test func playsTheOriginalWhenTranscodingIsOff() {
        let only4K = [versions[0]]
        #expect(VersionChooser.planStreaming(sources: only4K, preferred: nil, limit: StreamingLimit(quality: .fullHD), allowTranscoding: false) == .direct(versions[0]))
        #expect(VersionChooser.planStreaming(sources: only4K, preferred: nil, limit: StreamingLimit(quality: .fullHD), allowTranscoding: true) == .transcode(versions[0], .fullHD))
    }

    @Test func playsAnUnlabelledVersionAsItIs() {
        let mystery = version("mystery")
        #expect(VersionChooser.planStreaming(sources: [mystery], preferred: nil, limit: StreamingLimit(quality: .hd), allowTranscoding: true) == .direct(mystery))
    }
}

struct TrackChooserTests {
    let english = TrackChooser.Candidate(id: 3, language: "eng", isForced: false, isHearingImpaired: false, isDefault: false)
    let englishSDH = TrackChooser.Candidate(id: 4, language: "eng", isForced: false, isHearingImpaired: true, isDefault: false)
    let englishForced = TrackChooser.Candidate(id: 5, language: "eng", isForced: true, isHearingImpaired: false, isDefault: false)
    let french = TrackChooser.Candidate(id: 6, language: "fre", isForced: false, isHearingImpaired: false, isDefault: true)

    @Test func offChoosesNothing() {
        #expect(TrackChooser.subtitle(from: [english, englishForced], audioLanguage: "jpn", mode: .off, language: "eng") == nil)
    }

    @Test func forcedOnlyChoosesTheForcedTrack() {
        #expect(TrackChooser.subtitle(from: [english, englishForced], audioLanguage: "eng", mode: .forcedOnly, language: "eng") == 5)
        #expect(TrackChooser.subtitle(from: [english, french], audioLanguage: "eng", mode: .forcedOnly, language: "eng") == nil)
    }

    @Test func forcedOnlyKnowsAForcedTrackByItsName() {
        let named = TrackChooser.Candidate(id: 8, language: "eng", isForced: false, isHearingImpaired: false, isDefault: false,
                                           name: "English (Forced)")
        #expect(TrackChooser.subtitle(from: [english, named], audioLanguage: "eng", mode: .forcedOnly, language: "eng") == 8)
        #expect(TrackChooser.subtitle(from: [named, english], audioLanguage: "jpn", mode: .smart, language: "eng") == 3)
        #expect(TrackChooser.namesForced("Foreign Parts Only"))
        #expect(TrackChooser.namesForced("en--forced--"))
        #expect(!TrackChooser.namesForced("English SDH"))
        #expect(!TrackChooser.namesForced("Reinforcement"))
    }

    /// Real tracks: a full SDH track flagged forced, and SDH ones without the flag for it.
    @Test func goesByWhatTitlesSayOfFullSubtitlesAndCaptions() {
        let flaggedSDH = TrackChooser.Candidate(id: 9, language: "eng", isForced: true, isHearingImpaired: false, isDefault: true,
                                                name: "English SDH - TipsMovieZ")
        #expect(TrackChooser.subtitle(from: [flaggedSDH], audioLanguage: "eng", mode: .forcedOnly, language: "eng") == nil)
        let namedSDH = TrackChooser.Candidate(id: 10, language: "eng", isForced: false, isHearingImpaired: false, isDefault: true,
                                              name: "SDH")
        #expect(TrackChooser.subtitle(from: [namedSDH, english], audioLanguage: "eng", mode: .always, language: "eng") == 3)
        #expect(TrackChooser.subtitle(from: [english, namedSDH], audioLanguage: "eng", mode: .off, language: "eng", captions: true) == 10)
        #expect(!TrackChooser.namesCaptions("Accent"))
    }

    @Test func smartShowsFullSubtitlesForForeignAudio() {
        let tracks = [englishSDH, english, englishForced, french]
        #expect(TrackChooser.subtitle(from: tracks, audioLanguage: "jpn", mode: .smart, language: "eng") == 3)
        #expect(TrackChooser.subtitle(from: tracks, audioLanguage: "en", mode: .smart, language: "eng") == 5)
        #expect(TrackChooser.subtitle(from: [english], audioLanguage: "und", mode: .smart, language: "eng") == nil)
    }

    @Test func alwaysPrefersAFullTrackOverSDH() {
        #expect(TrackChooser.subtitle(from: [englishSDH, english], audioLanguage: "eng", mode: .always, language: "eng") == 3)
        #expect(TrackChooser.subtitle(from: [englishSDH], audioLanguage: "eng", mode: .always, language: "eng") == 4)
        #expect(TrackChooser.subtitle(from: [french], audioLanguage: "eng", mode: .always, language: "eng") == nil)
    }

    @Test func closedCaptionsShowCaptionsFirstWhateverTheMode() {
        let tracks = [english, englishSDH, englishForced, french]
        #expect(TrackChooser.subtitle(from: tracks, audioLanguage: "eng", mode: .off, language: "eng", captions: true) == 4)
        #expect(TrackChooser.subtitle(from: tracks, audioLanguage: "eng", mode: .forcedOnly, language: "eng", captions: true) == 4)
        #expect(TrackChooser.subtitle(from: [englishForced, english], audioLanguage: "eng", mode: .off, language: "eng", captions: true) == 3)
    }

    @Test func closedCaptionsFallBackToTheAudiosLanguage() {
        let frenchSDH = TrackChooser.Candidate(id: 7, language: "fra", isForced: false, isHearingImpaired: true, isDefault: false)
        #expect(TrackChooser.subtitle(from: [french, frenchSDH], audioLanguage: "fre", mode: .off, language: "eng", captions: true) == 7)
        #expect(TrackChooser.subtitle(from: [french], audioLanguage: "jpn", mode: .always, language: "eng", captions: true) == nil)
    }

    @Test func matchesLanguageTagsInAnyForm() {
        #expect(AppSettings.sameLanguage("eng", "en-US"))
        #expect(AppSettings.sameLanguage("fra", "fre"))
        #expect(AppSettings.sameLanguage("de", "ger"))
        #expect(!AppSettings.sameLanguage("eng", "spa"))
        #expect(!AppSettings.sameLanguage(nil, "eng"))
    }
}

struct AudioDescriptionTests {
    let main = TrackChooser.Candidate(id: 1, language: "eng", isForced: false, isHearingImpaired: false, isDefault: true)
    let described = TrackChooser.Candidate(id: 2, language: "eng", isForced: false, isHearingImpaired: false, isDefault: false,
                                           name: "Audio Description", describesVideo: true)
    let spanish = TrackChooser.Candidate(id: 3, language: "spa", isForced: false, isHearingImpaired: false, isDefault: false)

    @Test func audioDescriptionsPlayTheDescriptionInTheLanguageThatPlays() {
        #expect(TrackChooser.audio(from: [main, described, spanish], language: "", defaultId: 1, descriptions: true) == 2)
        #expect(TrackChooser.audio(from: [main, described, spanish], language: "eng", defaultId: 3, descriptions: true) == 2)
    }

    @Test func withoutADescriptionInTheLanguageTheMainMixPlays() {
        #expect(TrackChooser.audio(from: [main, described, spanish], language: "spa", defaultId: 1, descriptions: true) == 3)
        #expect(TrackChooser.audio(from: [main, spanish], language: "", defaultId: 1, descriptions: true) == nil)
    }

    @Test func theAudioLanguagePassesOverADescriptionListedFirst() {
        #expect(TrackChooser.audio(from: [described, main], language: "eng", defaultId: 1, descriptions: false) == 1)
        #expect(TrackChooser.audio(from: [described, main], language: "", defaultId: 1, descriptions: false) == nil)
    }

    @Test func anotherVersionKeepsTheDescription() {
        let otherMain = TrackChooser.Candidate(id: 5, language: "eng", isForced: false, isHearingImpaired: false, isDefault: true)
        let otherDescribed = TrackChooser.Candidate(id: 6, language: "eng", isForced: false, isHearingImpaired: false, isDefault: false,
                                                    describesVideo: true)
        #expect(TrackChooser.same(as: described, in: [otherMain, otherDescribed]) == 6)
        #expect(TrackChooser.same(as: main, in: [otherDescribed, otherMain]) == 5)
    }

    @Test func titlesNameAudioDescriptions() {
        for title in ["English AD", "Audio Description", "Descriptive Audio - English", "DVS", "Audiodescripción", "Deutsch Audiodeskription",
                      "Français (audiodescription)", "Svenska synstolkning"] {
            #expect(AccessibleMedia.namesAudioDescription(title), "\(title)")
        }
        for title in ["English - Dolby Digital - 5.1 - Default", "Commentary", "Arabic", "Headphones", ""] {
            #expect(!AccessibleMedia.namesAudioDescription(title), "\(title)")
        }
        #expect(!AccessibleMedia.namesAudioDescription(nil))
    }

    @Test func streamsCarryTheirTitlesDescription() {
        var stream = MediaStream(type: "Audio")
        stream.index = 2
        stream.title = "English AD"
        #expect(stream.isAudioDescription)
        #expect(TrackChooser.Candidate(stream)?.describesVideo == true)
        var subtitle = MediaStream(type: "Subtitle")
        subtitle.title = "English AD"
        #expect(!subtitle.isAudioDescription)
    }

    @Test func episodeCodesAreSaidInWords() {
        var episode = JellyfinItem(id: "e", name: "Pilot", type: "Episode")
        episode.parentIndexNumber = 1
        episode.indexNumber = 2
        #expect(episode.spokenEpisodeCode == "Season 1, Episode 2")
        episode.indexNumberEnd = 3
        #expect(episode.spokenEpisodeCode == "Season 1, Episodes 2 to 3")
        episode.parentIndexNumber = 0
        episode.indexNumberEnd = nil
        #expect(episode.spokenEpisodeCode == "Specials, Episode 2")
    }
}

@MainActor
struct WatchHistoryTests {
    private func makeHistory() -> WatchHistory {
        WatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "WatchHistory-\(UUID().uuidString).json"))
    }

    @Test func ignoresTheFirstFewPercent() {
        let history = makeHistory()
        history.record(key: "a", position: 60, duration: 6000, needsSync: false)
        #expect(history.resumePosition(for: "a") == nil)
        history.record(key: "a", position: 600, duration: 6000, needsSync: false)
        #expect(history.resumePosition(for: "a") == 600)
    }

    @Test func countsTheLastTenPercentAsWatched() {
        let history = makeHistory()
        history.record(key: "a", position: 5500, duration: 6000, needsSync: true)
        let entry = history.entry(for: "a")
        #expect(entry?.played == true)
        #expect(entry?.position == 0)
        #expect(history.resumePosition(for: "a") == nil)
        #expect(history.hasPendingSync)
    }

    @Test func neverSyncsLocalFiles() {
        let history = makeHistory()
        history.record(key: WatchHistory.fileKey(name: "Home Movie.mkv", size: 42), position: 300, duration: 1000, needsSync: true)
        #expect(!history.hasPendingSync)
    }

    @Test func survivesARelaunch() {
        let file = FileManager.default.temporaryDirectory.appending(path: "WatchHistory-\(UUID().uuidString).json")
        WatchHistory(file: file).markPlayed(true, key: "episode", needsSync: true)
        let reloaded = WatchHistory(file: file)
        #expect(reloaded.entry(for: "episode")?.played == true)
        #expect(reloaded.problem == nil)
    }

    /// Who's signed in, as the app's account store would say.
    private final class SignedIn {
        var key: String?
        init(_ key: String?) { self.key = key }
    }

    private func makeHistory(file: URL? = nil, signedIn: SignedIn) -> WatchHistory {
        WatchHistory(file: file ?? FileManager.default.temporaryDirectory.appending(path: "WatchHistory-\(UUID().uuidString).json"),
                     signIn: { signedIn.key })
    }

    @Test func keepsEachPersonsPlaceOnOneServer() {
        let signedIn = SignedIn("server/alex")
        let history = makeHistory(signedIn: signedIn)
        history.record(key: "film", position: 600, duration: 6000, needsSync: true)
        signedIn.key = "server/sam"
        #expect(history.entry(for: "film") == nil)
        #expect(!history.hasPendingSync)
        history.record(key: "film", position: 1200, duration: 6000, needsSync: true)
        #expect(history.resumePosition(for: "film") == 1200)
        signedIn.key = "server/alex"
        #expect(history.resumePosition(for: "film") == 600)
        #expect(history.hasPendingSync)
    }

    @Test func keepsFilesOnThisDeviceForEveryone() {
        let signedIn = SignedIn("server/alex")
        let history = makeHistory(signedIn: signedIn)
        let file = WatchHistory.fileKey(name: "Home Movie.mkv", size: 42)
        history.record(key: file, position: 300, duration: 1000, needsSync: false)
        signedIn.key = "other-server/sam"
        #expect(history.resumePosition(for: file) == 300)
    }

    @Test func sendsOnlyWhatThePersonSignedInWatchedOffline() async {
        let signedIn = SignedIn("server/alex")
        let history = makeHistory(signedIn: signedIn)
        let alexs = "alex-\(UUID().uuidString)", sams = "sam-\(UUID().uuidString)"
        history.record(key: alexs, position: 600, duration: 6000, needsSync: true)
        signedIn.key = "server/sam"
        history.record(key: sams, position: 600, duration: 6000, needsSync: true)

        await history.syncPending(using: HistorySyncStub.client, userId: "sam")
        #expect(HistorySyncStub.sent(alexs) == 0)
        #expect(HistorySyncStub.sent(sams) == 1)
        #expect(!history.hasPendingSync)
        signedIn.key = "server/alex"
        #expect(history.hasPendingSync)
        #expect(history.entry(for: alexs)?.needsSync == true)
    }

    @Test func givesWhatWasKeptBeforeSignInsWereToldApartToWhoeverSyncsFirst() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "WatchHistory-\(UUID().uuidString).json")
        let earlier = "earlier-\(UUID().uuidString)"
        WatchHistory(file: file).record(key: earlier, position: 600, duration: 6000, needsSync: true)

        let signedIn = SignedIn("server/alex")
        let history = makeHistory(file: file, signedIn: signedIn)
        #expect(history.resumePosition(for: earlier) == 600)
        await history.syncPending(using: HistorySyncStub.client, userId: "alex")
        #expect(HistorySyncStub.sent(earlier) == 1)
        #expect(history.resumePosition(for: earlier) == 600)
        signedIn.key = "server/sam"
        #expect(history.entry(for: earlier) == nil)
        signedIn.key = "server/alex"
        #expect(WatchHistory(file: file, signIn: { signedIn.key }).resumePosition(for: earlier) == 600)
    }
}

/// A server that takes every position it's sent, at a host of its own, so it answers only the
/// watch history's tests.
nonisolated final class HistorySyncStub: URLProtocol {
    private static let host = "watch-history.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    private static let registered: Void = { URLProtocol.registerClass(HistorySyncStub.self) }()

    @MainActor static var client: JellyfinClient {
        _ = registered
        return JellyfinClient(serverURL: URL(string: "https://\(host)")!, deviceId: "d", deviceName: "iPhone", token: "tok")
    }

    /// How many times the server was sent a position for `itemId`.
    static func sent(_ itemId: String) -> Int {
        lock.withLock { paths.filter { $0.contains("/\(itemId)/") }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil) else { return }
        Self.lock.withLock { Self.paths.append(url.path()) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct JellyfinFormatTests {
    @Test func parsesSevenDigitFractions() throws {
        let date = try #require(JellyfinDate.parse("2026-03-04T05:06:07.1234567Z"))
        #expect(date == Date(timeIntervalSince1970: 1_772_600_767))
        #expect(JellyfinDate.parse("2026-03-04T05:06:07Z") == date)
        #expect(JellyfinDate.parse("2026-03-04T07:06:07.5+02:00") == date)
        #expect(JellyfinDate.parse("yesterday") == nil)
    }

    @Test func asksForTranscodesNoBiggerThanTheQuality() throws {
        let profile = DeviceProfile.transcoding(maxHeight: 1080, maxBitrate: VideoQuality.fullHD.transcodeBitrate)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let conditions = try #require((json["CodecProfiles"] as? [[String: Any]])?.first?["Conditions"] as? [[String: Any]])
        #expect(conditions.contains { $0["Property"] as? String == "Height" && $0["Value"] as? String == "1080" })
        #expect(json["MaxStreamingBitrate"] as? Int == 16_000_000)
        let transcoding = try #require((json["TranscodingProfiles"] as? [[String: Any]])?.first)
        #expect(transcoding["Protocol"] as? String == "hls")
        #expect(DeviceProfile.transcoding(maxHeight: nil, maxBitrate: 1).CodecProfiles.isEmpty)
    }

    @Test func buildsSubtitleAndImageURLs() {
        let client = JellyfinClient(serverURL: URL(string: "https://jf.example.com")!, deviceId: "d", deviceName: "TV", token: "tok")
        #expect(client.externalSubtitleURL(itemId: "i", mediaSourceId: "m", streamIndex: 3, format: "srt").absoluteString
            == "https://jf.example.com/Videos/i/m/Subtitles/3/Stream.srt?ApiKey=tok")
        #expect(client.imageURL(itemId: "i", kind: .backdrop, tag: "t", maxWidth: 1280).absoluteString
            == "https://jf.example.com/Items/i/Images/Backdrop?maxWidth=1280&quality=90&tag=t")
    }
}

struct SmartDownloadPlannerTests {
    private func episodes(played: Int, total: Int, queued: Set<Int> = [], inProgress: Set<Int> = []) -> [SmartDownloadPlanner.Episode] {
        (1...total).map { number in
            SmartDownloadPlanner.Episode(id: "e\(number)", played: number <= played, inProgress: inProgress.contains(number),
                                         isQueued: queued.contains(number))
        }
    }

    @Test func startsAfterTheLastWatchedEpisode() {
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 3, total: 10), nextUpId: nil, count: 3) == ["e4", "e5", "e6"])
    }

    @Test func startsAtTheServersNextUp() {
        // Watching skipped ahead to episode 6: the server knows, so downloads follow.
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 3, total: 10), nextUpId: "e6", count: 2) == ["e6", "e7"])
    }

    @Test func keepsARollingWindowWithoutRequeueing() {
        let list = episodes(played: 2, total: 10, queued: [3, 4])
        #expect(SmartDownloadPlanner.episodesToDownload(list, nextUpId: nil, count: 4) == ["e5", "e6"])
    }

    @Test func takesEveryUnwatchedEpisodeWithoutACount() {
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 8, total: 10), nextUpId: nil, count: nil) == ["e9", "e10"])
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 10, total: 10), nextUpId: nil, count: nil).isEmpty)
    }

    @Test func takesSkippedAndNewEpisodesWhenKeepingEveryUnwatchedOne() {
        // Episode 2 was skipped, 3 is being watched again, 5 is queued, and 7 just arrived on the server.
        var list = episodes(played: 4, total: 6, queued: [5], inProgress: [3])
        list[1] = SmartDownloadPlanner.Episode(id: "e2", played: false, inProgress: false, isQueued: false)
        list.append(SmartDownloadPlanner.Episode(id: "e7", played: false, inProgress: false, isQueued: false))
        #expect(SmartDownloadPlanner.episodesToDownload(list, nextUpId: "e5", count: nil) == ["e2", "e3", "e6", "e7"])
    }

    @Test func startsFromAnEpisodeBeingWatchedAgain() {
        let list = episodes(played: 3, total: 6, queued: [2, 3], inProgress: [3])
        #expect(SmartDownloadPlanner.episodesToDownload(list, nextUpId: "e3", count: 2) == ["e4"])
    }

    @Test func passesOverANextUpFinishedHereFirst() {
        // The server still says e4 is next; it was finished offline and isn't synced yet.
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 4, total: 8), nextUpId: "e4", count: 2) == ["e5", "e6"])
    }
}

struct ResumeTests {
    @Test func resumesInsideTheVersion() {
        #expect(PlaybackResolver.resumable(40, length: 60) == 40)
        #expect(PlaybackResolver.resumable(40, length: nil) == 40)
    }

    @Test func startsOverPastTheEndOfAShorterVersion() {
        #expect(PlaybackResolver.resumable(40, length: 20) == nil)
        #expect(PlaybackResolver.resumable(19, length: 20) == nil)
        #expect(PlaybackResolver.resumable(0, length: 20) == nil)
        #expect(PlaybackResolver.resumable(nil, length: 20) == nil)
    }
}

struct LocalFileTests {
    @Test func findsSubtitlesNextToAVideo() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Sidecars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Movie.mkv", "Movie.srt", "Movie.en.forced.srt", "Movie.fre.sdh.ass", "Movie 2.srt", "Movie.txt"] {
            try Data().write(to: folder.appending(path: name))
        }
        let tracks = PlaybackResolver.sidecarSubtitles(for: folder.appending(path: "Movie.mkv"))
        #expect(tracks.map(\.name) == ["Movie.en.forced.srt", "Movie.fre.sdh.ass", "Movie.srt"])
        #expect(tracks.map(\.language) == ["en", "fre", nil])
        #expect(tracks.map(\.isForced) == [true, false, false])
        #expect(tracks.map(\.isHearingImpaired) == [false, true, false])
    }
}

@MainActor
struct TrackNamingTests {
    @Test func namesCodecsTheWayPeopleKnowThem() {
        #expect(PlayerModel.codecName("dca", profile: nil) == "DTS")
        #expect(PlayerModel.codecName("dts", profile: "DTS-HD MA") == "DTS-HD MA")
        #expect(PlayerModel.codecName("eac3", profile: "Dolby Digital Plus + Dolby Atmos") == "Dolby Digital Plus + Dolby Atmos")
        #expect(PlayerModel.codecName("truehd", profile: nil) == "Dolby TrueHD")
        #expect(PlayerModel.codecName("pcm_s24le", profile: nil) == "PCM")
        #expect(PlayerModel.codecName("hdmv_pgs_subtitle", profile: nil) == "PGS")
    }
}

/// What the player says when a playback fails: plain sentences, never the engine's or the
/// system's own wording.
struct PlaybackFailureMessageTests {
    private func engine(_ kind: PlaybackErrorKind, code: Int? = nil, domain: String? = nil) -> String {
        PlaybackFailureMessage.text(for: PlaybackErrorInfo(kind: kind, message: "Invalid data found when processing input",
                                                           underlyingDomain: domain, underlyingCode: code))
    }

    @Test func saysWhatEachKindOfEngineFailureMeans() {
        #expect(engine(.sourceRefused, code: 401) == "The server no longer accepts this sign-in. Sign in again to play this.")
        #expect(engine(.sourceRefused, code: 403).hasPrefix("This account isn't allowed to play this."))
        #expect(engine(.sourceRefused, code: 404).hasPrefix("The server couldn't find this video."))
        #expect(engine(.sourceRefused, code: 502) == "The server ran into a problem playing this.")
        #expect(engine(.sourceRefused, code: 410) == "The server turned down the request to play this.")
        #expect(engine(.sourceRateLimited, code: 429).hasPrefix("The server is too busy to play this right now."))
        #expect(engine(.sourceCertificateRejected, code: -1202).hasPrefix("The server's certificate isn't trusted"))
        #expect(engine(.storageExhausted) == "This device is full. Free up some space, then try again.")
        #expect(engine(.vodSourceFailed) == "The connection to the server was lost.")
        #expect(engine(.liveSourceUnavailable) == "The connection to the server was lost.")
        #expect(engine(.sourceOpenFailed) == "This video couldn't be opened. The file may be damaged.")
        #expect(engine(.dolbyVisionRequiresHardware) == "This device can't play this Dolby Vision video.")
        for kind in [PlaybackErrorKind.nativeItemFailed, .masterPlaylistRejected, .noPlayableTrackWithinBudget,
                     .softwarePipelineFailed, .hlsFormatUnsupported, .audioBridgeProducedNoOutput] {
            #expect(engine(kind) == "This device couldn't play this video.", "\(kind.rawValue)")
        }
        #expect(engine(PlaybackErrorKind(rawValue: "somethingNew")) == PlaybackFailureMessage.unknown)
    }

    @Test func aConnectionFailureUnderneathReadsAsTheConnections() {
        #expect(engine(.nativeItemFailed, code: URLError.notConnectedToInternet.rawValue, domain: NSURLErrorDomain)
            .hasPrefix("This device is offline."))
        #expect(engine(.sourceOpenFailed, code: URLError.cannotConnectToHost.rawValue, domain: NSURLErrorDomain)
            .hasPrefix("The server can't be reached."))
        // Not when the kind already says what went wrong.
        #expect(engine(.storageExhausted, code: URLError.timedOut.rawValue, domain: NSURLErrorDomain).hasPrefix("This device is full."))
    }

    @Test func saysWhatTheCommonConnectionErrorsMean() {
        func text(_ code: URLError.Code) -> String { PlaybackFailureMessage.text(for: URLError(code)) }
        #expect(text(.notConnectedToInternet) == "This device is offline. Connect to the internet, then try again.")
        #expect(text(.networkConnectionLost) == "The connection to the server was lost.")
        for code in [URLError.Code.cannotConnectToHost, .cannotFindHost, .timedOut, .dnsLookupFailed] {
            #expect(text(code) == "The server can't be reached. It may be off, or on another network.")
        }
        #expect(text(.serverCertificateUntrusted).hasPrefix("The server's certificate isn't trusted"))
        #expect(text(.userAuthenticationRequired).hasSuffix("Sign in again to play this."))
        #expect(text(.badServerResponse) == "The server sent something that isn't a video.")
        // As a plain NSError too, as AVFoundation passes them on.
        let wrapped = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        #expect(PlaybackFailureMessage.text(for: wrapped).hasPrefix("This device is offline."))
    }

    @Test func keepsTheAppsOwnWordsAndHidesEveryoneElses() {
        #expect(PlaybackFailureMessage.text(for: PlaybackError.noVersions) == PlaybackError.noVersions.localizedDescription)
        let refused = JellyfinError.http(status: 401, body: "")
        #expect(PlaybackFailureMessage.text(for: refused) == refused.localizedDescription)
        let engineError = NSError(domain: "AetherEngine.DemuxerError", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: "avformat_open_input failed: -1094995529"])
        #expect(PlaybackFailureMessage.text(for: engineError) == PlaybackFailureMessage.unknown)
        // The engine's account of its own failure classifies it better than what it threw.
        let info = PlaybackErrorInfo(kind: .storageExhausted, message: "ENOSPC")
        #expect(PlaybackFailureMessage.text(for: engineError, engine: info).hasPrefix("This device is full."))
    }

    @Test func anEpisodeNotOutYetIsSaidAsAnEpisode() {
        var episode = JellyfinItem(id: "e7", name: "Open Water", type: "Episode")
        episode.parentIndexNumber = 2
        episode.indexNumber = 6
        #expect(PlaybackError.notYetAvailable(episode).localizedDescription
            == "S02E06 · Open Water isn't on the server yet. It plays here once the server has the episode.")
        let movie = JellyfinItem(id: "m", name: "Copperline", type: "Movie")
        #expect(PlaybackError.notYetAvailable(movie).localizedDescription.hasPrefix("Copperline isn't out yet."))
    }
}

/// Something that ends when it's opened, for a load that waits on something slow to stop.
@MainActor
private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }

    func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class Record {
    var committed: [String] = []
    var cancelled: [String] = []
}

/// One load at a time: a newer one replaces one still under way, whatever order their waits end
/// in, and a countdown to the next episode started before a load has nothing left to do.
@MainActor
struct LoadSequenceTests {
    @Test func aLoadReplacedWhileItWaitsDoesNothingWhenItsWaitEnds() async {
        let loads = LoadSequence()
        let gate = Gate()
        let record = Record()
        // The earlier pick's request comes back after the later pick's has.
        let earlier = Task {
            await loads.start { generation in
                await gate.wait()
                if Task.isCancelled { record.cancelled.append("earlier") }
                if loads.isCurrent(generation) { record.committed.append("earlier") }
            }
        }
        while !gate.isWaiting { await Task.yield() }
        await loads.start { generation in
            if loads.isCurrent(generation) { record.committed.append("later") }
        }
        gate.open()
        await earlier.value
        #expect(record.committed == ["later"])
        #expect(record.cancelled == ["earlier"])
    }

    @Test func cancellingTheCallerCancelsItsLoad() async {
        let loads = LoadSequence()
        let record = Record()
        let caller = Task {
            await loads.start { _ in
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { record.cancelled.append("load") }
            }
        }
        caller.cancel()
        await caller.value
        #expect(record.cancelled == ["load"])
    }

    @Test func aCountdownStartedBeforeAnotherLoadDoesNothingWhenItRunsOut() async {
        let loads = LoadSequence()
        await loads.start { _ in }
        let countdown = UpNextCountdown(generation: loads.generation, episodeId: "e5", nextEpisodeId: "e6", startedInCredits: false)
        #expect(countdown.isDue(loads: loads, onScreen: "e5", next: "e6", isEnding: true))
        // Play Again, or a move back on the timeline, during the countdown loads the episode again.
        await loads.start { _ in }
        #expect(!countdown.isDue(loads: loads, onScreen: "e5", next: "e6", isEnding: true))
    }

    @Test func aCountdownIsDueOnlyForTheEpisodeItStartedInAndTheOneItCountedTo() async {
        let loads = LoadSequence()
        await loads.start { _ in }
        let countdown = UpNextCountdown(generation: loads.generation, episodeId: "e5", nextEpisodeId: "e6", startedInCredits: true)
        // Moved back out of the credits.
        #expect(!countdown.isDue(loads: loads, onScreen: "e5", next: "e6", isEnding: false))
        #expect(!countdown.isDue(loads: loads, onScreen: "e4", next: "e6", isEnding: true))
        #expect(!countdown.isDue(loads: loads, onScreen: "e5", next: "e7", isEnding: true))
        #expect(!countdown.isDue(loads: loads, onScreen: "e5", next: nil, isEnding: true))
    }

    @Test func theCreditsCountDownLongerThanTheEnd() {
        var fromCredits = UpNextCountdown(generation: 1, episodeId: "e5", nextEpisodeId: "e6", startedInCredits: true)
        #expect(fromCredits.length == 10)
        #expect(fromCredits.remaining == 10)
        #expect(fromCredits.progress == 0)
        fromCredits.remaining = 4
        #expect(abs(fromCredits.progress - 0.6) < 0.0001)
        let fromEnd = UpNextCountdown(generation: 1, episodeId: "e5", nextEpisodeId: "e6", startedInCredits: false)
        #expect(fromEnd.length == 5)
    }
}

/// The end of an episode: when the up-next card offers the next one, and what it's about.
struct TitleEndingTests {
    private static func outro(from start: Double, to end: Double) -> MediaSegment {
        MediaSegment(type: "Outro", startTicks: Int64(start * 10_000_000), endTicks: Int64(end * 10_000_000))
    }

    private let credits = TitleEnding(duration: 1500, segments: [Self.outro(from: 1380, to: 1500)])
    private let unmarked = TitleEnding(duration: 1500, segments: [])

    @Test func theCardComesWithTheCreditsTheServerMarks() {
        #expect(credits.creditsStart == 1380)
        #expect(credits.upNextPhase(at: 1379, hasEnded: false) == nil)
        #expect(credits.upNextPhase(at: 1380, hasEnded: false) == .credits)
        #expect(credits.upNextPhase(at: 1499, hasEnded: false) == .credits)
        #expect(credits.upNextPhase(at: 1500, hasEnded: true) == .ended)
    }

    @Test func withoutCreditsMarkedTheCardOffersTheNextEpisodeForTheLastHalfMinute() {
        #expect(unmarked.creditsStart == nil)
        #expect(unmarked.upNextPhase(at: 1469, hasEnded: false) == nil)
        #expect(unmarked.upNextPhase(at: 1470, hasEnded: false) == .nearEnd)
        #expect(unmarked.upNextPhase(at: 1500, hasEnded: true) == .ended)
    }

    @Test func aShortTitleGetsNoCard() {
        let extra = TitleEnding(duration: 90, segments: [Self.outro(from: 60, to: 90)])
        #expect(extra.upNextPhase(at: 80, hasEnded: false) == nil)
        #expect(extra.upNextPhase(at: 90, hasEnded: true) == nil)
    }

    @Test func leavingInTheCreditsFinishesTheTitle() {
        // Closed, or moved on to any other episode, once the credits start.
        #expect(credits.finishes(leavingAt: 1380, toNextEpisode: false))
        #expect(credits.finishes(leavingAt: 1450, toNextEpisode: false))
        #expect(!credits.finishes(leavingAt: 1379, toNextEpisode: false))
        // A movie's credits count too.
        let movie = TitleEnding(duration: 6000, segments: [Self.outro(from: 5700, to: 6000)])
        #expect(movie.finishes(leavingAt: 5800, toNextEpisode: false))
        #expect(!movie.finishes(leavingAt: 5000, toNextEpisode: false))
    }

    @Test func movingOnWhileTheCardOffersTheNextEpisodeFinishesTheTitle() {
        // Play Now or Next in the last half minute, with no credits marked.
        #expect(unmarked.finishes(leavingAt: 1480, toNextEpisode: true))
        // Closing there leaves it where it got to, and so does moving on before the card.
        #expect(!unmarked.finishes(leavingAt: 1480, toNextEpisode: false))
        #expect(!unmarked.finishes(leavingAt: 1200, toNextEpisode: true))
    }
}

/// After episodes that started by themselves with nobody doing anything, the player asks before
/// starting another.
struct UnattendedAutoplayTests {
    @Test func asksAfterThreeEpisodesStartedByThemselves() {
        var unattended = UnattendedAutoplay()
        for _ in 0..<2 { unattended.episodeStartedByItself() }
        #expect(!unattended.asksFirst)
        unattended.episodeStartedByItself()
        #expect(unattended.asksFirst)
    }

    @Test func anythingTheViewerDoesStartsTheCountOver() {
        var unattended = UnattendedAutoplay()
        for _ in 0..<2 { unattended.episodeStartedByItself() }
        unattended.viewerActed()
        for _ in 0..<2 { unattended.episodeStartedByItself() }
        #expect(!unattended.asksFirst)
        #expect(unattended.count == 2)
    }
}

/// Closing the player after it moved on to later episodes lands on the page of the one watched
/// last.
struct ClosingBackToWhatPlayedTests {
    private static func episode(_ id: String, show: String = "s") -> JellyfinItem {
        var episode = JellyfinItem(id: id, name: id, type: "Episode")
        episode.seriesId = show
        return episode
    }

    @Test func theStartingEpisodesPageShowsTheEpisodeWatchedLast() {
        let ended = EndedPlayback(count: 1, userData: ["e3": UserItemData(playbackPositionTicks: 600_000_000)],
                                  startedItemId: "e1", lastItem: Self.episode("e3"))
        let shown = ended.episodeToShow(onPageOf: Self.episode("e1"))
        #expect(shown?.id == "e3")
        // With the watch state the playback left it in.
        #expect(shown?.resumeSeconds == 60)
    }

    @Test func otherPagesStayAsTheyAre() {
        let ended = EndedPlayback(count: 1, startedItemId: "e1", lastItem: Self.episode("e3"))
        // Another episode's page, or the episode that played last.
        #expect(ended.episodeToShow(onPageOf: Self.episode("e2")) == nil)
        #expect(ended.episodeToShow(onPageOf: Self.episode("e3")) == nil)
        // Nothing moved on.
        let same = EndedPlayback(count: 1, startedItemId: "e1", lastItem: Self.episode("e1"))
        #expect(same.episodeToShow(onPageOf: Self.episode("e1")) == nil)
        // Another show, as SharePlay can move to.
        let elsewhere = EndedPlayback(count: 1, startedItemId: "e1", lastItem: Self.episode("x1", show: "other"))
        #expect(elsewhere.episodeToShow(onPageOf: Self.episode("e1")) == nil)
    }
}

/// Where the end screen of a movie or a show's last episode leads back to.
struct EndScreenReturnTests {
    @Test func aMovieGoesBackToItsDetails() {
        let movie = JellyfinItem(id: "m", name: "Copperline", type: "Movie")
        let way = EndScreenReturn(for: movie)
        #expect(way.page.id == "m")
        #expect(way.label == "Back to Details")
    }

    @Test func aShowsLastEpisodeGoesBackToTheShow() {
        var finale = JellyfinItem(id: "e12", name: "Open Water", type: "Episode")
        finale.seriesId = "s"
        finale.seriesName = "Port Ellery"
        let way = EndScreenReturn(for: finale)
        #expect(way.page.id == "s")
        #expect(way.page.isSeries)
        #expect(way.label == "Back to Port Ellery")
    }
}

/// Resuming a saved position backs up a moment; where another device, a link or the group asked
/// to start stays exact.
struct ResumeLeadInTests {
    private let episode = PlaybackRequest(source: .item(id: "e5", mediaSourceId: nil), title: "Fog Signals")

    @Test func aSavedPositionResumesAMomentBefore() {
        #expect(episode.start(resuming: 2530) == 2530 - PlaybackRequest.resumeLeadIn)
        #expect(episode.resumesSavedPosition(2530))
        // Never before the start, which is then no resume.
        #expect(episode.start(resuming: 3) == 0)
        #expect(!episode.resumesSavedPosition(3))
        #expect(!episode.resumesSavedPosition(nil))
    }

    @Test func anAskedStartingPointIsExact() {
        var asked = episode
        asked.startingPoint = .init(position: 600)
        #expect(asked.start(resuming: 2530) == 600)
        #expect(!asked.resumesSavedPosition(2530))
        // Try Again and a move back after the end start exactly where they ask.
        #expect(episode.retrying(from: 2400).start(resuming: 600) == 2400)
        #expect(!episode.retrying(from: 2400).resumesSavedPosition(600))
        #expect(!episode.replaying(from: 1800, title: "").resumesSavedPosition(600))
    }
}

/// What the player starts with: the item as the screen had it, and as the title's page loaded it.
struct ShownItemTests {
    @Test func theRequestCarriesTheItemForItsPicture() {
        var episode = JellyfinItem(id: "e5", name: "Fog Signals", type: "Episode")
        episode.seriesName = "Port Ellery"
        let request = PlaybackRequest.item(episode)
        #expect(request.shownItem == episode)
        #expect(request.loadedItem == nil)
    }

    @Test func onlyAnItemWithItsDetailsSavesTheFetch() {
        var listed = JellyfinItem(id: "e5", name: "Fog Signals", type: "Episode")
        listed.mediaSources = [MediaSource(id: "v1", name: "v1")]
        // A list's episode, versions and all, but without its chapters and previews.
        #expect(PlaybackRequest.item(listed, loaded: listed).loadedItem == nil)
        var detailed = listed
        detailed.chapters = []
        #expect(PlaybackRequest.item(detailed, loaded: detailed).loadedItem == detailed)
        // Another title's item is no use.
        #expect(PlaybackRequest.item(JellyfinItem(id: "e6", name: "", type: "Episode"), loaded: detailed).loadedItem == nil)
    }
}

/// Skip Intros: when an intro skips by itself.
struct IntroSkippingTests {
    @Test func skipsByTheSetting() {
        #expect(!AppSettings.IntroSkipping.ask.skips(inARow: true))
        #expect(AppSettings.IntroSkipping.inARow.skips(inARow: true))
        #expect(!AppSettings.IntroSkipping.inARow.skips(inARow: false))
        #expect(AppSettings.IntroSkipping.always.skips(inARow: false))
    }

    @Test func asksUnlessChosenAndIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "IntroSkippingTests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.introSkipping == .ask)
        settings.introSkipping = .inARow
        #expect(AppSettings(defaults: defaults).introSkipping == .inARow)
    }
}

/// The requests a playback that ended plays again with, and a failed one tries again with.
struct ReplayAndRetryTests {
    private let episode = PlaybackRequest(source: .item(id: "e5", mediaSourceId: nil), title: "Fog Signals")

    @Test func playAgainStartsFromTheBeginning() {
        let again = episode.replaying(from: 0, title: "Fog Signals")
        #expect(again.startFromBeginning)
        #expect(again.startingPoint == nil)
        #expect(again.source == episode.source)
    }

    @Test func movingBackAfterTheEndPlaysFromExactlyThere() {
        let again = episode.replaying(from: 1800, title: "Fog Signals")
        #expect(!again.startFromBeginning)
        #expect(again.start(resuming: 600) == 1800)
        // Not from a resume position further on, as a handed-off playback would.
        #expect(again.start(resuming: 2400) == 1800)
    }

    @Test func tryAgainStartsWhereThePlaybackGotTo() {
        var startOver = episode
        startOver.startFromBeginning = true
        let again = startOver.retrying(from: 2400)
        #expect(!again.startFromBeginning)
        #expect(again.start(resuming: nil) == 2400)
        #expect(again.start(resuming: 600) == 2400)
    }

    @Test func tryAgainKeepsTheStreamsAnotherDeviceAskedFor() {
        var asked = episode
        asked.startingPoint = .init(position: 60, audioStreamIndex: 2, subtitleStreamIndex: -1)
        let again = asked.retrying(from: 300)
        #expect(again.startingPoint == .init(position: 300, audioStreamIndex: 2, subtitleStreamIndex: -1))
    }

    @Test func tryAgainBeforeAnythingPlayedIsTheSameRequest() {
        var asked = episode
        asked.startingPoint = .init(position: 60, yieldsToLaterResume: true)
        #expect(asked.retrying(from: nil) == asked)
        #expect(asked.retrying(from: 0) == asked)
    }

    @Test func knowsTheSameTitleInAnyVersion() {
        let other = PlaybackRequest(source: .item(id: "e5", mediaSourceId: "v2"), title: "")
        #expect(episode.playsSameTitle(as: other))
        #expect(!episode.playsSameTitle(as: PlaybackRequest(source: .item(id: "e6", mediaSourceId: nil), title: "")))
        let file = PlaybackRequest(source: .file(bookmark: Data([1, 2]), name: "Movie.mkv"), title: "Movie")
        #expect(file.playsSameTitle(as: PlaybackRequest(source: .file(bookmark: Data([1, 2]), name: "Movie.mkv"), title: "")))
        #expect(!file.playsSameTitle(as: episode))
    }

    @Test func aSavedRequestLeavesTheLoadedItemOut() throws {
        var request = episode
        request.loadedItem = JellyfinItem(id: "e5", name: "Fog Signals", type: "Episode")
        let restored = try JSONDecoder().decode(PlaybackRequest.self, from: JSONEncoder().encode(request))
        #expect(restored.loadedItem == nil)
        #expect(restored.id == request.id)
        #expect(restored.source == request.source)
        #expect(restored.title == request.title)
    }
}

/// The audio and subtitles another stream of the title keeps: Try Again, Play Through the
/// Server, a move to a lower quality.
@MainActor
struct CarriedTracksTests {
    private let settings = AppSettings(defaults: UserDefaults(suiteName: "CarriedTracksTests-\(UUID().uuidString)")!)

    private func stream(_ type: String, _ index: Int, _ language: String, title: String? = nil, forced: Bool = false) -> MediaStream {
        var stream = MediaStream(type: type)
        stream.index = index
        stream.language = language
        stream.title = title
        stream.isForced = forced
        return stream
    }

    private func version(_ id: String, _ streams: [MediaStream]) -> MediaSource {
        var source = MediaSource(id: id, name: id)
        source.mediaStreams = streams
        return source
    }

    private var original: MediaSource {
        version("v1", [stream("Audio", 1, "jpn"), stream("Audio", 2, "eng"),
                       stream("Subtitle", 3, "eng", title: "Signs", forced: true), stream("Subtitle", 4, "eng"), stream("Subtitle", 5, "eng")])
    }

    private func selection(audio: Int?, subtitle: Int?, in source: MediaSource) -> TrackSelection {
        TrackSelection(
            audio: source.audioStreams.first { $0.index == audio }.flatMap(TrackChooser.Candidate.init),
            subtitle: source.subtitleStreams.first { $0.index == subtitle }.flatMap(TrackChooser.Candidate.init),
            streams: .init(mediaSourceId: source.id, audio: audio, subtitle: subtitle)
        )
    }

    @Test func theSameVersionGetsTheVeryStreams() {
        // The second of two English subtitles alike, under Japanese audio.
        let tracks = selection(audio: 1, subtitle: 5, in: original)
        let indexes = tracks.streamIndexes(in: original, settings: settings)
        #expect(indexes.audio == 1)
        #expect(indexes.subtitle == 5)
    }

    @Test func subtitlesThatWereOnStayOnThroughTheServer() {
        // Known only by language, as on a file the server's list doesn't number the same.
        var tracks = selection(audio: 1, subtitle: 4, in: original)
        tracks.streams = nil
        #expect(tracks.streamIndexes(in: original, settings: settings).subtitle == 4)
        // In a version without them, the ones the subtitle setting takes rather than none.
        settings.subtitleMode = .always
        let other = version("v2", [stream("Audio", 0, "jpn"), stream("Subtitle", 1, "fre"), stream("Subtitle", 2, "eng", title: "Full")])
        var elsewhere = tracks
        elsewhere.subtitle = TrackChooser.Candidate(id: 9, language: "ger", isForced: false, isHearingImpaired: false, isDefault: false)
        #expect(elsewhere.streamIndexes(in: other, settings: settings).subtitle == 2)
    }

    @Test func anotherVersionGetsTheSameLanguageAndKind() {
        let tracks = selection(audio: 1, subtitle: 3, in: original)
        let other = version("v2", [stream("Audio", 0, "eng"), stream("Audio", 1, "jpn"),
                                   stream("Subtitle", 2, "eng"), stream("Subtitle", 3, "eng", title: "Signs", forced: true)])
        let indexes = tracks.streamIndexes(in: other, settings: settings)
        #expect(indexes.audio == 1)
        #expect(indexes.subtitle == 3)
    }

    @Test func subtitlesThatWereOffStayOff() {
        settings.subtitleMode = .always
        let indexes = selection(audio: 2, subtitle: nil, in: original).streamIndexes(in: original, settings: settings)
        #expect(indexes.audio == 2)
        #expect(indexes.subtitle == nil)
    }

    @Test func audioTheVersionHasntGotFallsBackToTheLanguageSetting() {
        let tracks = TrackSelection(audio: TrackChooser.Candidate(id: 7, language: "ita", isForced: false, isHearingImpaired: false, isDefault: false))
        #expect(tracks.streamIndexes(in: original, settings: settings).audio == 2)
    }
}

/// The audio and subtitles the viewer picked in a show, which its other episodes start with: this
/// session's picks, then those remembered from last time, then the language settings. What another
/// device asked for, and the tracks a stream of the same title had, come first.
@MainActor
struct TrackPicksTests {
    private let settings = AppSettings(defaults: UserDefaults(suiteName: "TrackPicksTests-\(UUID().uuidString)")!)

    private func stream(_ type: String, _ index: Int, _ language: String, title: String? = nil, forced: Bool = false) -> MediaStream {
        var stream = MediaStream(type: type)
        stream.index = index
        stream.language = language
        stream.title = title
        stream.isForced = forced
        return stream
    }

    /// The next episode: English audio first, then Japanese; signs, then full English subtitles.
    private var nextEpisode: MediaSource {
        var source = MediaSource(id: "e6", name: "e6")
        source.mediaStreams = [stream("Audio", 1, "eng"), stream("Audio", 2, "jpn"),
                               stream("Subtitle", 3, "eng", title: "Signs", forced: true), stream("Subtitle", 4, "eng")]
        return source
    }

    private func track(_ language: String, forced: Bool = false) -> TrackPicks.Track {
        TrackPicks.Track(TrackChooser.Candidate(id: 9, language: language, isForced: forced, isHearingImpaired: false, isDefault: false))
    }

    private var japaneseWithSubtitles: TrackPicks {
        TrackPicks(audio: track("jpn"), subtitles: .track(track("eng")))
    }

    @Test func theNextEpisodeKeepsTheAudioAndSubtitlesPicked() {
        let indexes = PlaybackResolver.streamIndexes(in: nextEpisode, asked: nil, carrying: nil, picks: japaneseWithSubtitles,
                                                     settings: settings)
        #expect(indexes.audio == 2)
        #expect(indexes.subtitle == 4)
    }

    @Test func withoutPicksTheSettingsDecide() {
        // English audio, and Forced Only's signs.
        let indexes = PlaybackResolver.streamIndexes(in: nextEpisode, asked: nil, carrying: nil, picks: nil, settings: settings)
        #expect(indexes.audio == 1)
        #expect(indexes.subtitle == 3)
    }

    @Test func whatWasntPickedStaysWithTheSettings() {
        // Only the audio was picked: the subtitles are Forced Only's.
        let audioOnly = TrackPicks(audio: track("jpn"))
        let indexes = PlaybackResolver.streamIndexes(in: nextEpisode, asked: nil, carrying: nil, picks: audioOnly, settings: settings)
        #expect(indexes.audio == 2)
        #expect(indexes.subtitle == 3)
        // Subtitles turned off stay off, forced ones too.
        let off = TrackPicks(subtitles: .off)
        #expect(PlaybackResolver.streamIndexes(in: nextEpisode, asked: nil, carrying: nil, picks: off, settings: settings).subtitle == nil)
    }

    @Test func aPickTheEpisodeHasntGotFallsBackToTheSettings() {
        let german = TrackPicks(audio: track("ger"), subtitles: .track(track("ger")))
        let indexes = PlaybackResolver.streamIndexes(in: nextEpisode, asked: nil, carrying: nil, picks: german, settings: settings)
        #expect(indexes.audio == 1)
        #expect(indexes.subtitle == 3)
    }

    @Test func anotherDevicesAskComesFirstThenTheTitlesOwnTracks() {
        let asked = PlaybackRequest.StartingPoint(position: 0, audioStreamIndex: 1, subtitleStreamIndex: -1)
        let fromAsked = PlaybackResolver.streamIndexes(in: nextEpisode, asked: asked, carrying: nil, picks: japaneseWithSubtitles,
                                                       settings: settings)
        #expect(fromAsked.audio == 1)
        #expect(fromAsked.subtitle == nil)
        // A stream of the same title standing in for another keeps that one's tracks.
        let playing = TrackSelection(audio: track("eng").candidate, subtitle: nil)
        let carried = PlaybackResolver.streamIndexes(in: nextEpisode, asked: nil, carrying: playing, picks: japaneseWithSubtitles,
                                                     settings: settings)
        #expect(carried.audio == 1)
        #expect(carried.subtitle == nil)
    }

    @Test func thisSessionsPicksComeBeforeThoseRemembered() {
        let remembered = TrackPicks(audio: track("eng"), subtitles: .off)
        let session = TrackPicks(audio: track("jpn"))
        let starting = TrackPicks.starting(session: session, remembered: remembered)
        #expect(starting?.audio == track("jpn"))
        // Subtitles weren't picked this session: last time's stand.
        #expect(starting?.subtitles == .off)
        #expect(TrackPicks.starting(session: nil, remembered: remembered) == remembered)
        #expect(TrackPicks.starting(session: nil, remembered: nil) == nil)
    }

    @Test func eachShowRemembersItsLastPicks() {
        var memory = TrackMemory()
        memory.remember(TrackPicks(audio: track("jpn")), forShow: "anime")
        memory.remember(TrackPicks(subtitles: .track(track("eng"))), forShow: "anime")
        // Subtitles picked later keep the audio picked before.
        #expect(memory.picks(forShow: "anime") == japaneseWithSubtitles)
        #expect(memory.picks(forShow: "drama") == nil)
        memory.remember(TrackPicks(audio: track("eng")), forShow: "anime")
        #expect(memory.picks(forShow: "anime")?.audio == track("eng"))
    }

    @Test func memoryKeepsTheShowsPickedInMostRecently() {
        var memory = TrackMemory()
        for show in 0...TrackMemory.capacity { memory.remember(TrackPicks(audio: track("jpn")), forShow: "show \(show)") }
        #expect(memory.picks(forShow: "show 0") == nil)
        #expect(memory.picks(forShow: "show 1") != nil)
        #expect(memory.picks(forShow: "show \(TrackMemory.capacity)") != nil)
    }

    @Test func memoryLastsFromOneLaunchToTheNext() throws {
        let defaults = try #require(UserDefaults(suiteName: "TrackPicksTests-\(UUID().uuidString)"))
        let before = AppSettings(defaults: defaults)
        before.trackMemory.remember(japaneseWithSubtitles, forShow: "anime")
        #expect(AppSettings(defaults: defaults).trackMemory.picks(forShow: "anime") == japaneseWithSubtitles)
    }
}

struct PlayerDetailTests {
    @Test @MainActor func numbersEpisodesForNowPlaying() {
        var episode = JellyfinItem(id: "e", name: "Breakwater", type: "Episode")
        episode.parentIndexNumber = 1
        episode.indexNumber = 4
        #expect(PlayerModel.nowPlayingEpisodeNumber(episode) == "S1, E4")
        episode.indexNumberEnd = 5
        #expect(PlayerModel.nowPlayingEpisodeNumber(episode) == "S1, E4–5")
        episode.parentIndexNumber = nil
        #expect(PlayerModel.nowPlayingEpisodeNumber(episode) == "E4–5")
        episode.indexNumber = nil
        #expect(PlayerModel.nowPlayingEpisodeNumber(episode) == nil)
    }

    @Test func takesTheChaptersMarkedInAFile() {
        let marks = [
            ChapterInfo(id: 2, name: "", startSeconds: 600, durationSeconds: 300),
            ChapterInfo(id: 1, name: " Opening ", startSeconds: 0, durationSeconds: 600),
        ]
        let chapters = PlaybackResolver.chapters(from: marks)
        #expect(chapters.map(\.start) == [0, 600])
        #expect(chapters.map(\.name) == ["Opening", "Chapter 2"])
        #expect(chapters.allSatisfy { $0.image == nil })
    }
}

/// A short silent H.264 video, a keyframe a second, written for a test to play.
private enum GeneratedVideo {
    static let size = (width: 320, height: 180)
    static let framesPerSecond = 10

    static func write(seconds: Int) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "GeneratedVideo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Generated.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: framesPerSecond],
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                                                         size: CVImageSize(width: size.width, height: size.height))
        let frames = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * framesPerSecond) {
            let buffer = try CVMutablePixelBuffer(attributes)
            buffer.withUnsafeBuffer { pixels in
                CVPixelBufferLockBaseAddress(pixels, [])
                // A shade a frame, so no two frames are alike.
                memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 3 % 256), CVPixelBufferGetDataSize(pixels))
                CVPixelBufferUnlockBaseAddress(pixels, [])
            }
            try await frames.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
        }
        frames.finish()
        await withCheckedContinuation { finished in writer.finishWriting { finished.resume() } }
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}

/// A playback through the engine, at its edges: moving back once it ended, playing it again, a
/// press while it starts. Plays a video it writes.
@MainActor
@Suite(.serialized)
struct PlaybackEdgeTests {
    private func makeModel(playing file: URL, engine: AetherEngine) throws -> PlayerModel {
        let defaults = try #require(UserDefaults(suiteName: "PlaybackEdgeTests-\(UUID().uuidString)"))
        let accounts = AccountStore(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        let history = WatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "Edges-\(UUID().uuidString).json"))
        let resolver = PlaybackResolver(accounts: accounts, settings: settings, history: history) { _, _ in nil }
        return PlayerModel(request: try .file(file), engine: engine, lease: EngineLease(),
                           resolver: resolver, accounts: accounts, history: history, settings: settings) { _ in nil }
    }

    private static func episode(_ id: String, _ number: Int) -> JellyfinItem {
        var episode = JellyfinItem(id: id, name: "Episode \(number)", type: "Episode")
        episode.seriesId = "show"
        episode.seriesName = "Show"
        episode.parentIndexNumber = 1
        episode.indexNumber = number
        return episode
    }

    /// Two episodes downloaded, both `file`, the first playing.
    private func makeModel(playingEpisodesOf file: URL, engine: AetherEngine) throws -> PlayerModel {
        try makeBinge(episodes: 2, of: file, engine: engine).model
    }

    /// A show's episodes, downloaded, each of them `file` with `segments` marked, the first playing.
    private struct Binge {
        let model: PlayerModel
        let settings: AppSettings
        let history: WatchHistory
    }

    private func makeBinge(episodes count: Int, of file: URL, segments: [MediaSegment] = [], engine: AetherEngine,
                           firstResumesAt resume: Double? = nil, length: Double? = nil,
                           settings configure: (AppSettings) -> Void = { _ in }) throws -> Binge {
        var episodes = (1...count).map { Self.episode("e\($0)", $0) }
        if let resume, let length {
            episodes[0].runTimeTicks = Int64(length * 10_000_000)
            episodes[0].userData = UserItemData(playbackPositionTicks: Int64(resume * 10_000_000))
        }
        let defaults = try #require(UserDefaults(suiteName: "PlaybackEdgeTests-\(UUID().uuidString)"))
        let accounts = AccountStore(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        configure(settings)
        let history = WatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "Edges-\(UUID().uuidString).json"))
        let resolver = PlaybackResolver(accounts: accounts, settings: settings, history: history) { id, _ in
            episodes.first { $0.id == id }.map { PlaybackResolver.DownloadedCopy(url: file, item: $0, segments: segments) }
        }
        let model = PlayerModel(request: .item(episodes[0]), engine: engine, lease: EngineLease(),
                                resolver: resolver, accounts: accounts, history: history, settings: settings) { episode in
            episodes.firstIndex { $0.id == episode.id }.flatMap { $0 + 1 < episodes.count ? episodes[$0 + 1] : nil }
        }
        return Binge(model: model, settings: settings, history: history)
    }

    private static func segment(_ type: String, from start: Double, to end: Double) -> MediaSegment {
        MediaSegment(type: type, startTicks: Int64(start * 10_000_000), endTicks: Int64(end * 10_000_000))
    }

    private func waitUntil(seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func playToTheEnd(_ model: PlayerModel) async throws {
        await model.start()
        try await waitUntil { model.status == .ended }
        try #require(model.status == .ended, "Didn't end: \(model.status)")
    }

    @Test func movingBackAfterTheEndPlaysAgainFromThere() async throws {
        let file = try await GeneratedVideo.write(seconds: 8)
        let model = try makeModel(playing: file, engine: try AetherEngine())
        try await playToTheEnd(model)
        // The title stays on screen for the controls, and plays from the start on another device.
        #expect(model.current != nil)
        #expect(model.handOverPosition == 0)

        model.seek(to: 3)
        try await waitUntil { model.status == .playing && model.clock.time > 3.2 }
        #expect(model.status == .playing)
        #expect(model.clock.time >= 3 && model.clock.time < 7, "Played from \(model.clock.time)")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func goingBackTenSecondsAfterTheEndPlaysTheEndAgain() async throws {
        let file = try await GeneratedVideo.write(seconds: 15)
        let model = try makeModel(playing: file, engine: try AetherEngine())
        await model.start()
        try await waitUntil { model.status == .playing }
        model.seek(to: 12)
        try await waitUntil { model.status == .ended }
        try #require(model.status == .ended)
        let end = model.clock.time

        model.skip(by: -PlayerModel.skipInterval)
        try await waitUntil { model.status == .playing && model.clock.time > end - PlayerModel.skipInterval + 0.2 }
        #expect(model.status == .playing)
        #expect(model.clock.time < end - 5, "Played from \(model.clock.time), the end at \(end)")

        // Forward from the end has nowhere to go.
        try await waitUntil { model.status == .ended }
        model.skip(by: PlayerModel.skipInterval)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.status == .ended)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func playAgainStartsFromTheBeginning() async throws {
        let file = try await GeneratedVideo.write(seconds: 6)
        let model = try makeModel(playing: file, engine: try AetherEngine())
        try await playToTheEnd(model)

        model.togglePlayPause()
        try await waitUntil { model.status == .playing && model.clock.time > 0.2 }
        #expect(model.status == .playing)
        #expect(model.clock.time < 3, "Played again from \(model.clock.time)")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func playWhileMovingTheTimelineJumpsThereAndPlays() async throws {
        let file = try await GeneratedVideo.write(seconds: 20)
        let model = try makeModel(playing: file, engine: try AetherEngine())
        await model.start()
        try await waitUntil { model.status == .playing && model.clock.time > 0.5 }
        model.togglePlayPause()
        try await waitUntil { model.status == .paused }
        try #require(model.status == .paused)

        // Paused, the timeline moved on: Play, the on-screen button's or the remote's, plays from
        // the position chosen, and the timeline lets go of it.
        let paused = model.clock.time
        model.scrub(by: 8)
        try #require(model.scrubbing.isActive)
        model.togglePlayPause()
        #expect(!model.scrubbing.isActive)
        try await waitUntil { model.status == .playing && model.clock.time > paused + 8.2 }
        #expect(model.status == .playing)
        #expect(model.clock.time >= paused + 7.5 && model.clock.time < paused + 11, "Played from \(model.clock.time)")

        // Playing, the timeline moved back: Play plays on from there rather than pausing.
        let playing = model.clock.time
        model.scrub(by: -6)
        model.togglePlayPause()
        #expect(!model.scrubbing.isActive)
        try await waitUntil { model.status == .playing && model.clock.time < playing - 3 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.status == .playing)
        #expect(model.clock.time < playing - 3, "Played from \(model.clock.time), the timeline moved back from \(playing)")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func theCountdownPlaysTheNextEpisodeWhenItRunsOut() async throws {
        let file = try await GeneratedVideo.write(seconds: 4)
        let model = try makeModel(playingEpisodesOf: file, engine: try AetherEngine())
        try await playToTheEnd(model)
        try await waitUntil { model.upNextCountdown != nil }
        try #require(model.upNextCountdown != nil, "No countdown")

        try await waitUntil(seconds: 20) { model.item?.id == "e2" && model.status == .playing }
        #expect(model.item?.id == "e2")
        #expect(model.status == .playing)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func watchAgainDuringTheCountdownStaysOnTheEpisode() async throws {
        let file = try await GeneratedVideo.write(seconds: 4)
        let model = try makeModel(playingEpisodesOf: file, engine: try AetherEngine())
        try await playToTheEnd(model)
        try await waitUntil { model.upNextCountdown != nil }
        try #require(model.upNextCountdown != nil, "No countdown")

        model.watchAgain()
        try await waitUntil { model.status == .playing }
        #expect(model.upNextCountdown == nil)
        // Past the end of the countdown it was in.
        try await Task.sleep(for: .seconds(6))
        #expect(model.item?.id == "e1")
        #expect(model.requestedItemId == "e1")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func playPauseAtTheEndPlaysTheNextEpisode() async throws {
        let file = try await GeneratedVideo.write(seconds: 4)
        let binge = try makeBinge(episodes: 2, of: file, engine: try AetherEngine()) { $0.autoplayNextEpisode = false }
        let model = binge.model
        try await playToTheEnd(model)
        try await waitUntil { model.nextEpisode != nil }
        #expect(model.upNextCountdown == nil)
        #expect(model.upNextPhase(at: model.clock.time) == nil, "A title this short gets no card")

        // The one way on from the end, as a click on the timeline or Play/Pause on the remote.
        model.togglePlayPause()
        try await waitUntil { model.item?.id == "e2" && model.status == .playing }
        #expect(model.item?.id == "e2")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func backDuringTheEndCountdownStopsItAndLeavesTheEpisodeEnded() async throws {
        let file = try await GeneratedVideo.write(seconds: 4)
        let model = try makeModel(playingEpisodesOf: file, engine: try AetherEngine())
        try await playToTheEnd(model)
        try await waitUntil { model.upNextCountdown != nil }
        try #require(model.upNextCountdown != nil, "No countdown")

        model.cancelUpNext()
        #expect(model.upNextCountdown == nil)
        try await Task.sleep(for: .seconds(6))
        #expect(model.status == .ended)
        #expect(model.item?.id == "e1")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func theCountdownStartsWithTheCreditsAndRunsOnPastTheEnd() async throws {
        // Credits from 125 s of 130.
        let file = try await GeneratedVideo.write(seconds: 130)
        let model = try makeBinge(episodes: 2, of: file, segments: [Self.segment("Outro", from: 125, to: 130)],
                                  engine: try AetherEngine()).model
        await model.start()
        try await waitUntil { model.status == .playing }
        try await waitUntil { !model.segments.isEmpty }
        model.seek(to: 123)
        try await waitUntil { model.upNextCountdown != nil }
        let countdown = try #require(model.upNextCountdown, "No countdown in the credits")
        #expect(countdown.startedInCredits)
        #expect(countdown.length == UpNextCountdown.fromCredits)
        #expect(model.status != .ended)
        #expect(model.upNextPhase(at: model.clock.time) == .credits)

        // The file ends five seconds in, and the countdown goes on rather than starting over.
        try await waitUntil { model.status == .ended }
        let atEnd = try #require(model.upNextCountdown, "The countdown stopped at the end")
        #expect(atEnd.startedInCredits)
        #expect(atEnd.remaining < UpNextCountdown.fromCredits)

        try await waitUntil(seconds: 20) { model.item?.id == "e2" && model.status == .playing }
        #expect(model.item?.id == "e2")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func watchCreditsStopsTheCountdownAndTheEndOffersTheNextEpisode() async throws {
        let file = try await GeneratedVideo.write(seconds: 130)
        let model = try makeBinge(episodes: 2, of: file, segments: [Self.segment("Outro", from: 125, to: 130)],
                                  engine: try AetherEngine()).model
        await model.start()
        try await waitUntil { model.status == .playing }
        try await waitUntil { !model.segments.isEmpty }
        model.seek(to: 124)
        try await waitUntil { model.upNextCountdown != nil }
        try #require(model.upNextCountdown != nil, "No countdown in the credits")

        model.cancelUpNext()
        #expect(model.upNextCountdown == nil)
        #expect(model.upNextPhase(at: model.clock.time) == nil)
        try await waitUntil { model.status == .ended }
        try await Task.sleep(for: .seconds(2))
        // Back as the way on, without counting down.
        #expect(model.upNextPhase(at: model.clock.time) == .ended)
        #expect(model.upNextCountdown == nil)
        #expect(model.item?.id == "e1")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func movingBackOutOfTheCreditsStopsTheirCountdown() async throws {
        let file = try await GeneratedVideo.write(seconds: 130)
        let model = try makeBinge(episodes: 2, of: file, segments: [Self.segment("Outro", from: 120, to: 130)],
                                  engine: try AetherEngine()).model
        await model.start()
        try await waitUntil { model.status == .playing }
        try await waitUntil { !model.segments.isEmpty }
        model.seek(to: 121)
        try await waitUntil { model.upNextCountdown != nil }
        try #require(model.upNextCountdown != nil, "No countdown in the credits")

        model.seek(to: 60)
        try await waitUntil { model.upNextCountdown == nil }
        #expect(model.upNextCountdown == nil)
        #expect(model.upNextPhase(at: model.clock.time) == nil)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func leavingInTheCreditsReportsTheEpisodeWatched() async throws {
        let file = try await GeneratedVideo.write(seconds: 8)
        let binge = try makeBinge(episodes: 2, of: file, segments: [Self.segment("Outro", from: 3, to: 8)], engine: try AetherEngine())
        let model = binge.model
        await model.start()
        try await waitUntil { model.status == .playing && model.clock.time > 3.5 }
        try #require(model.clock.time < 7, "Played past the credits before the test caught it")

        await model.close()
        await model.stopReport?.value
        #expect(binge.history.entry(for: "e1")?.played == true)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func leavingBeforeTheCreditsKeepsWhereItGotTo() async throws {
        let file = try await GeneratedVideo.write(seconds: 20)
        let binge = try makeBinge(episodes: 2, of: file, segments: [Self.segment("Outro", from: 15, to: 20)], engine: try AetherEngine())
        let model = binge.model
        await model.start()
        try await waitUntil { model.status == .playing && model.clock.time > 1.5 }

        await model.close()
        await model.stopReport?.value
        let entry = try #require(binge.history.entry(for: "e1"))
        #expect(!entry.played)
        #expect(entry.position < 15)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func movingOnInTheCreditsReportsTheEpisodeWatched() async throws {
        let file = try await GeneratedVideo.write(seconds: 8)
        let binge = try makeBinge(episodes: 2, of: file, segments: [Self.segment("Outro", from: 3, to: 8)], engine: try AetherEngine())
        let model = binge.model
        await model.start()
        try await waitUntil { model.status == .playing && model.clock.time > 3.5 && model.nextEpisode != nil }
        try #require(model.clock.time < 7, "Played past the credits before the test caught it")

        await model.playNextEpisode()
        try await waitUntil { model.item?.id == "e2" }
        await model.stopReport?.value
        #expect(binge.history.entry(for: "e1")?.played == true)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func afterThreeEpisodesThatStartedByThemselvesItAsksFirst() async throws {
        let file = try await GeneratedVideo.write(seconds: 2)
        let model = try makeBinge(episodes: 5, of: file, engine: try AetherEngine()).model
        await model.start()
        // Three countdowns run out with nobody doing anything.
        try await waitUntil(seconds: 120) { model.item?.id == "e4" && model.status == .ended }
        try #require(model.item?.id == "e4", "Got to \(model.item?.id ?? "nothing")")
        try await waitUntil { model.asksStillWatching }
        #expect(model.asksStillWatching)
        #expect(model.upNextCountdown == nil)
        try await Task.sleep(for: .seconds(UpNextCountdown.fromEnd + 1))
        #expect(model.item?.id == "e4")

        // Someone's there: the next one plays.
        await model.continueWatching()
        try await waitUntil { model.item?.id == "e5" && model.status == .playing }
        #expect(!model.asksStillWatching)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func theViewerUsingThePlayerStartsTheCountOver() async throws {
        let file = try await GeneratedVideo.write(seconds: 2)
        let model = try makeBinge(episodes: 5, of: file, engine: try AetherEngine()).model
        await model.start()
        // Two episodes started by themselves; a third would ask at its end. Its two seconds of
        // playing can pass between two looks while other suites hold the main actor, so the
        // viewer acts as soon as it's on.
        var seen: [String] = []
        try await waitUntil(seconds: 90) {
            let state = "\(model.item?.id ?? "-") \(model.status)"
            if seen.last != state { seen.append(state) }
            return model.item?.id == "e3"
        }
        try #require(model.item?.id == "e3" && !model.asksStillWatching, "Went \(seen.joined(separator: ", "))")
        model.noteViewerActivity()
        try await waitUntil(seconds: 120) { model.item?.id == "e5" && model.status == .ended }
        #expect(model.item?.id == "e5")
        #expect(!model.asksStillWatching)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func skipIntrosAlwaysSkipsTheIntroAndOffersItBack() async throws {
        let file = try await GeneratedVideo.write(seconds: 12)
        let model = try makeBinge(episodes: 1, of: file, segments: [Self.segment("Intro", from: 1, to: 6)], engine: try AetherEngine()) {
            $0.introSkipping = .always
        }.model
        await model.start()
        try await waitUntil { model.clock.time >= 6 }
        #expect(model.clock.time >= 6)
        guard case .skippedIntro(let intro) = model.chip else {
            Issue.record("No chip: \(String(describing: model.chip))")
            return
        }
        #expect(intro.start == 1)

        // Watch It goes back, and the intro then plays.
        model.watchIntro()
        #expect(model.chip == nil)
        try await waitUntil { model.clock.time < 3 && model.status == .playing }
        try await waitUntil { model.clock.time > 3 }
        #expect(model.clock.time < 6, "Skipped again: \(model.clock.time)")

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func skipIntrosInARowLeavesTheFirstEpisodesIntro() async throws {
        let file = try await GeneratedVideo.write(seconds: 8)
        let model = try makeBinge(episodes: 2, of: file, segments: [Self.segment("Intro", from: 1, to: 6)], engine: try AetherEngine()) {
            $0.introSkipping = .inARow
        }.model
        await model.start()
        try await waitUntil { model.clock.time > 2.5 }
        #expect(model.clock.time < 6)
        #expect(model.chip == nil)

        // Moved on to the next one, its intro skips.
        await model.playNextEpisode()
        try await waitUntil { model.item?.id == "e2" && model.clock.time >= 6 }
        #expect(model.clock.time >= 6)
        #expect(model.chip != nil)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func aResumeBacksUpAndOffersToStartOver() async throws {
        let file = try await GeneratedVideo.write(seconds: 20)
        let model = try makeBinge(episodes: 1, of: file, engine: try AetherEngine(), firstResumesAt: 12, length: 20).model
        await model.start()
        try await waitUntil { model.status == .playing }
        #expect(model.chip == .resumed(at: 12 - PlaybackRequest.resumeLeadIn))
        #expect(model.clock.time >= 12 - PlaybackRequest.resumeLeadIn - 1 && model.clock.time < 12)

        model.startOver()
        #expect(model.chip == nil)
        try await waitUntil { model.clock.time < 3 }
        #expect(model.clock.time < 3)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Paused and staying so: the engine paused, its clock not moving, the model saying so.
    private func expectHeldPaused(_ model: PlayerModel, _ engine: AetherEngine) async throws {
        // Past the start, by when the picture is up, or would have been.
        try await Task.sleep(for: .seconds(2))
        #expect(model.status == .paused)
        #expect(engine.state == .paused)
        let held = engine.clock.currentTime
        try await Task.sleep(for: .seconds(1))
        #expect(engine.clock.currentTime == held)
        #expect(model.status == .paused)
    }

    @Test func aPauseWhileItStartsHoldsThroughTheFirstPicture() async throws {
        let file = try await GeneratedVideo.write(seconds: 6)
        let engine = try AetherEngine()
        let model = try makeModel(playing: file, engine: engine)
        let starting = Task { await model.start() }
        await Task.yield()
        #expect(model.status == .preparing)
        model.togglePlayPause()
        #expect(model.status == .paused)
        await starting.value
        try await expectHeldPaused(model, engine)

        model.togglePlayPause()
        try await waitUntil(seconds: 15) { model.status == .playing && model.clock.time > 0.5 }
        #expect(model.status == .playing)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func aPauseWhileTheEngineLoadsHoldsOnceItHasLoaded() async throws {
        let file = try await GeneratedVideo.write(seconds: 6)
        let engine = try AetherEngine()
        let model = try makeModel(playing: file, engine: engine)
        let starting = Task { await model.start() }
        let deadline = ContinuousClock.now + .seconds(10)
        while model.status == .preparing, ContinuousClock.now < deadline { await Task.yield() }
        try #require(model.status == .loading)
        // The engine's load is under way, and starts the stream as it returns.
        model.togglePlayPause()
        #expect(model.status == .paused)
        await starting.value
        try await expectHeldPaused(model, engine)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func playPressedAfterAPauseWhileItStartsPlaysIt() async throws {
        let file = try await GeneratedVideo.write(seconds: 6)
        let model = try makeModel(playing: file, engine: try AetherEngine())
        let starting = Task { await model.start() }
        await Task.yield()
        model.togglePlayPause()
        model.togglePlayPause()
        #expect(model.status == .preparing)
        await starting.value
        try await waitUntil(seconds: 15) { model.status == .playing && model.clock.time > 0.5 }
        #expect(model.status == .playing)

        await model.close()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

