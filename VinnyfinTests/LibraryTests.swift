import AetherEngine
import CoreGraphics
import Foundation
import Testing
@testable import vinnyfin

/// An episode as the server lists it with everything a download keeps beside the file.
private enum Extras {
    static let item = Samples.item("""
    {"Id":"e1","Name":"Pilot","Type":"Episode","SeriesId":"show","SeriesName":"Test Show","SeriesPrimaryImageTag":"sp",
     "ParentIndexNumber":1,"IndexNumber":1,"ImageTags":{"Primary":"p","Logo":"l"},"BackdropImageTags":[],
     "ParentBackdropItemId":"show","ParentBackdropImageTags":["b"],
     "Trickplay":{"e1":{
       "240":{"Width":240,"Height":135,"TileWidth":10,"TileHeight":10,"ThumbnailCount":150,"Interval":10000},
       "320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":150,"Interval":10000},
       "640":{"Width":640,"Height":360,"TileWidth":10,"TileHeight":10,"ThumbnailCount":150,"Interval":10000}}},
     "Chapters":[{"StartPositionTicks":0,"Name":"Opening","ImageTag":"c0"},
                 {"StartPositionTicks":6000000000,"Name":" "},
                 {"StartPositionTicks":12000000000,"Name":"Credits","ImageTag":"c2"}],
     "MediaSources":[{"Id":"e1","Name":"1080p","Size":300000000,"Path":"/media/pilot.mkv","MediaStreams":[
       {"Type":"Subtitle","Index":1,"Codec":"subrip","Language":"eng","IsExternal":false},
       {"Type":"Subtitle","Index":2,"Codec":"subrip","Language":"eng","IsExternal":true},
       {"Type":"Subtitle","Index":3,"Codec":"subrip","Language":"eng","IsExternal":true,"IsForced":true},
       {"Type":"Subtitle","Index":4,"Codec":"ass","Language":"fre","IsExternal":true,"IsHearingImpaired":true},
       {"Type":"Subtitle","Index":5,"Codec":"subrip","Language":"eng","IsExternal":true,"Title":"Commentary"},
       {"Type":"Subtitle","Index":6,"Codec":"webvtt","IsExternal":true}]}]}
    """)

    #if !os(tvOS)
    static let storage = DownloadStorage(finished: URL(filePath: "/tmp/Finished"), root: URL(filePath: "/tmp/Root"))

    static func job(saved: Bool = false, now: Date = .now) -> DownloadJob {
        var job = DownloadJob(item: item, source: item.mediaSources![0], now: now)
        if saved { job.savedPath = "Test Show/Season 01/Test Show - S01E01 - Pilot.mkv" }
        return job
    }

    /// The job once its look-up has taken the version's segments and chapters.
    static func lookedUp(_ job: DownloadJob, at date: Date = .now) -> DownloadJob {
        var job = job
        job.segments = []
        job.extrasItemId = job.versionItemId
        job.extrasCheckedAt = date
        return job
    }
    #endif

    /// The same episode with a second version, which is an item of its own.
    static let withAlternate: JellyfinItem = {
        var episode = Extras.item
        episode.mediaSources?.append(MediaSource(id: "v2", name: "720p"))
        return episode
    }()
}

#if !os(tvOS)
struct DownloadExtrasTests {
    @Test func plansArtworkPreviewsAndChapterPicturesFromTheStart() {
        let job = Extras.job()
        let files = DownloadExtras.files(for: job, storage: Extras.storage)
        let folder = Extras.storage.extrasFolder(for: job.id)
        #expect(files.map(\.remote) == [
            .artwork(itemId: "e1", kind: .primary, tag: "p", width: 600),
            .artwork(itemId: "show", kind: .backdrop, tag: "b", width: 1280),
            .artwork(itemId: "e1", kind: .logo, tag: "l", width: 900),
            .artwork(itemId: "show", kind: .primary, tag: "sp", width: 600),
            .trickplaySheet(itemId: "e1", mediaSourceId: "e1", width: 320, index: 0),
            .trickplaySheet(itemId: "e1", mediaSourceId: "e1", width: 320, index: 1),
            .chapterImage(itemId: "e1", index: 0, tag: "c0"),
            .chapterImage(itemId: "e1", index: 2, tag: "c2"),
        ])
        // The show's backdrop is saved as the episode's own; the show's poster is shared.
        #expect(files[1].local == Extras.storage.artworkFile(itemId: "e1", kind: .backdrop))
        #expect(files.map(\.isOwn) == [true, true, true, false, true, true, true, true])
        #expect(files[5].local == folder.appending(path: "Trickplay/320/1.jpg"))
        #expect(files[7].local == folder.appending(path: "Chapters/2-c2.jpg"))
    }

    @Test func savesExternalSubtitlesBesideThePublishedFile() {
        let subtitles = DownloadExtras.files(for: Extras.job(saved: true), storage: Extras.storage).filter {
            if case .subtitle = $0.remote { true } else { false }
        }
        let folder = Extras.storage.finished.appending(path: "Test Show/Season 01")
        // The embedded track (1) stays in the file; two English SRTs share a name, so they're numbered.
        #expect(subtitles.map(\.local) == [
            folder.appending(path: "Test Show - S01E01 - Pilot.eng.2.srt"),
            folder.appending(path: "Test Show - S01E01 - Pilot.eng.forced.srt"),
            folder.appending(path: "Test Show - S01E01 - Pilot.fre.sdh.ass"),
            folder.appending(path: "Test Show - S01E01 - Pilot.eng.5.srt"),
            folder.appending(path: "Test Show - S01E01 - Pilot.und.vtt"),
        ])
        #expect(subtitles.first?.remote == .subtitle(itemId: "e1", mediaSourceId: "e1", streamIndex: 2, format: "srt"))
    }

    @Test func looksUpThenTakesEachMissingFileThenStops() {
        var job = Extras.job(saved: true)
        #expect(DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { _ in false }, now: .now) == .lookUp)
        job = Extras.lookedUp(job)
        let files = DownloadExtras.files(for: job, storage: Extras.storage)
        let first = DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { _ in false }, now: .now)
        #expect(first == .file(files[0]))
        let have = Set(files.dropLast().map(\.local))
        #expect(DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { have.contains($0) }, now: .now) == .file(files.last!))
        #expect(DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { _ in true }, now: .now) == nil)
    }

    @Test func keepsTheDownloadedVersionsOwnChaptersAndSegments() {
        let alternate = Extras.withAlternate.mediaSources![1]
        var job = DownloadJob(item: Extras.withAlternate, source: alternate)
        // The item lists its own version's chapters, so the other version's wait for the look-up.
        #expect(job.item?.chapters == nil)
        #expect(job.versionItemId == "v2")
        job = Extras.lookedUp(job)
        #expect(!DownloadExtras.needsLookUp(job, now: .now))
        job.item?.chapters = Extras.item.chapters
        let pictures = DownloadExtras.files(for: job, storage: Extras.storage).compactMap { file -> String? in
            if case .chapterImage(let itemId, _, _) = file.remote { itemId } else { nil }
        }
        #expect(pictures == ["v2", "v2"])
        // Saved when segments and chapters were the item's own version's, it's looked up again.
        job.extrasItemId = nil
        #expect(DownloadExtras.needsLookUp(job, now: .now))
    }

    @Test func looksTheItemUpAgainWhileItLacksPreviewsForAWeek() {
        let queued = Date(timeIntervalSince1970: 1_000_000)
        var job = Extras.job(now: queued)
        #expect(DownloadExtras.needsLookUp(job, now: queued), "never looked up")
        job = Extras.lookedUp(job, at: queued)
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(3_600)))
        #expect(DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(2 * 86_400)), "a chapter has no picture yet")
        let pictured = job.item?.chapters?.filter { $0.imageTag != nil }
        job.item?.chapters = pictured
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(2 * 86_400)))
        job.item?.trickplay = nil
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(3_600)))
        #expect(DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(2 * 86_400)))
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(8 * 86_400)))
    }

    @Test func handsPlaybackOnlyTheFilesOnDisk() {
        let job = Extras.job(saved: true)
        let files = DownloadExtras.files(for: job, storage: Extras.storage)
        let sheet = Extras.storage.extrasFolder(for: job.id).appending(path: "Trickplay/320/0.jpg")
        let subtitle = files.first { $0.remote == .subtitle(itemId: "e1", mediaSourceId: "e1", streamIndex: 4, format: "ass") }!.local
        let saved = DownloadExtras.saved(for: job, storage: Extras.storage) { $0 == sheet || $0 == subtitle }
        #expect(saved.trickplaySheets == [0: sheet])
        #expect(saved.subtitles == [4: subtitle])
        #expect(saved.chapterImages.isEmpty)
    }
}
#endif

struct PlaybackExtrasTests {
    @Test func listsChaptersOnlyForTheItemsOwnVersion() {
        let client = JellyfinClient(serverURL: URL(string: "https://jf.example.com")!, deviceId: "d", deviceName: "iPhone", token: "tok")
        let item = Extras.withAlternate
        let own = PlaybackResolver.chapters(of: item, playing: item.mediaSources![0], client: client)
        #expect(own.map(\.name) == ["Opening", "Chapter 2", "Credits"])
        #expect(own.first?.image?.path() == "/Items/e1/Images/Chapter/0")
        #expect(PlaybackResolver.chapters(of: item, playing: item.mediaSources![1], client: client).isEmpty)
    }

    @Test func picksTheSmallestPreviewsAtLeastThePlayersWidth() {
        #expect(TrickplayTiles.width(among: [240, 320, 640]) == 320)
        #expect(TrickplayTiles.width(among: [480, 640]) == 480)
        #expect(TrickplayTiles.width(among: [160, 240]) == 240)
        #expect(TrickplayTiles.width(among: [Int]()) == nil)
    }

    @Test func findsEachThumbnailOnItsSheet() throws {
        let tiles = try #require(TrickplayTiles.of(Extras.item, sourceId: "e1") { _, index in URL(filePath: "/sheet\(index).jpg") })
        #expect(tiles.sheets.count == 2)
        #expect(tiles.thumbnail(at: 0)?.sheet == 0)
        #expect(tiles.thumbnail(at: 0)?.rect == CGRect(x: 0, y: 0, width: 320, height: 180))
        // 125 seconds is the 13th thumbnail: third across, second down.
        #expect(tiles.thumbnail(at: 125)?.rect == CGRect(x: 640, y: 180, width: 320, height: 180))
        #expect(tiles.thumbnail(at: 1_005)?.sheet == 1)
        #expect(tiles.thumbnail(at: 1_005)?.rect == CGRect(x: 0, y: 0, width: 320, height: 180))
        // Past the end, the last thumbnail.
        #expect(tiles.thumbnail(at: 99_999)?.rect == CGRect(x: 2_880, y: 720, width: 320, height: 180))
        #expect(TrickplayTiles.of(Extras.item, sourceId: "e1") { _, index in index == 0 ? URL(filePath: "/a") : nil } == nil)
        #expect(TrickplayTiles.of(Extras.item, sourceId: "other") { _, _ in URL(filePath: "/a") } == nil)
    }

    @Test func namesChaptersAndFindsTheOnePlaying() {
        let chapters = ChapterMark.of(Extras.item) { index, _ in URL(filePath: "/chapter\(index).jpg") }
        #expect(chapters.map(\.name) == ["Opening", "Chapter 2", "Credits"])
        #expect(chapters.map(\.image) == [URL(filePath: "/chapter0.jpg"), nil, URL(filePath: "/chapter2.jpg")])
        #expect(ChapterMark.current(in: chapters, at: 0)?.index == 0)
        #expect(ChapterMark.current(in: chapters, at: 900)?.index == 1)
        #expect(ChapterMark.current(in: chapters, at: 5_000)?.index == 2)
    }

    @Test func offersOnlyTheServersSubtitleFiles() {
        let source = Extras.item.mediaSources![0]
        let tracks = ExternalSubtitleTrack.of(source) { _, index, format in
            index == 6 ? nil : URL(filePath: "/sub\(index).\(format)")
        }
        #expect(tracks.map(\.url) == [2, 3, 4, 5].map { index in
            URL(filePath: "/sub\(index).\(index == 4 ? "ass" : "srt")")
        })
        #expect(tracks.map(\.isForced) == [false, true, false, false])
        #expect(tracks[2].isHearingImpaired)
        #expect(tracks[3].name == "Commentary")
    }
}

#if !os(tvOS)
struct DownloadEstimateTests {
    private func plan(_ size: Int64?) -> DownloadPlan {
        var source = MediaSource(id: UUID().uuidString)
        source.size = size
        return .original(source)
    }

    @Test func addsUpTheListedSizes() {
        let estimate = DownloadEstimate([plan(2_000_000_000), plan(1_500_000_000), nil])
        #expect(estimate.count == 2)
        #expect(estimate.bytes == 3_500_000_000)
        #expect(estimate.summary(noun: "episode", plural: "episodes") == "2 episodes, \(DownloadEstimate.text(3_500_000_000))")
        #expect(estimate.fits(in: 4_000_000_000))
        #expect(estimate.fits(in: nil))
        #expect(estimate.shortfall(space: 4_000_000_000) == nil)
        #expect(estimate.shortfall(space: 1_000_000_000)?.hasPrefix("Only \(DownloadEstimate.text(1_000_000_000)) is free") == true)
    }

    @Test func saysWhichSizesArentListed() {
        let some = DownloadEstimate([plan(2_000_000_000), plan(nil), plan(500)])
        #expect(some.unknownCount == 2)
        #expect(some.summary(noun: "episode", plural: "episodes")
            == "3 episodes, at least \(DownloadEstimate.text(2_000_000_000)): 2 sizes aren't listed")
        #expect(DownloadEstimate([plan(nil)]).summary(noun: "episode", plural: "episodes") == "1 episode, sizes not listed")
        #expect(DownloadEstimate([]).summary(noun: "episode", plural: "episodes") == "No episodes")
    }
}

struct DownloadsSnapshotTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000)

    private func job(_ id: String, _ status: DownloadJob.Status, minutesIn: Double, total: Int64? = 1_000, done: Int64 = 0) -> DownloadJob {
        var item = Samples.item(#"{"Id":"\#(id)","Name":"Episode \#(id)","Type":"Episode","SeriesName":"Show","ParentIndexNumber":1,"IndexNumber":1}"#)
        item.mediaSources = [Samples.source]
        var job = DownloadJob(item: item, source: Samples.source, now: Self.start.addingTimeInterval(minutesIn * 60))
        job.status = status
        job.totalBytes = total
        if done > 0 { job.completed.insert(0..<done) }
        if status == .completed { job.completedAt = Self.start.addingTimeInterval(minutesIn * 60) }
        return job
    }

    @Test func listsDownloadsInQueueOrderAndUnwatchedOnesReady() {
        // Moved to the front of the queue, "first" downloads before the older "second".
        let jobs = [
            job("paused", .paused, minutesIn: 0, done: 100),
            job("first", .active, minutesIn: 2, done: 450),
            job("second", .active, minutesIn: 1),
            job("old", .completed, minutesIn: 3, done: 1_000),
            job("new", .completed, minutesIn: 4, done: 1_000),
            job("seen", .completed, minutesIn: 5, done: 1_000),
        ]
        let snapshot = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: jobs[1].id, isHeldForPlayback: false,
                                         isNetworkReachable: true, isWatched: { $0.itemId == "seen" })
        #expect(snapshot.downloads.map(\.id) == ["first", "second", "paused"])
        #expect(snapshot.downloads.map(\.state) == [.downloading, .queued, .paused])
        #expect(snapshot.downloads.map(\.percent) == [45, 0, 10])
        #expect(snapshot.unfinishedCount == 3)
        #expect(snapshot.activeCount == 2)
        #expect(snapshot.ready.map(\.id) == ["new", "old"])
        #expect(snapshot.readyCount == 2)
        #expect(snapshot.current?.title.playLink == URL(string: "vinnyfin://play/first?type=Episode&name=Episode%20first"))
        #expect(snapshot.summary
            == "Episode first is downloading, 45% done, with 1 more after it. 1 download is paused. 2 downloads are ready to watch offline.")
        #expect(snapshot.line == "Episode first 45% · 1 more")
        #expect(snapshot.isRunning)
        #expect(snapshot.pausedCount == 1)
        #expect(snapshot.stoppedCount == 0)
    }

    /// Resuming continues what's paused; a download that stopped on a failure waits for Retry in
    /// the app, which the control and Siri say rather than calling it paused.
    @Test func tellsStoppedDownloadsFromPausedOnes() throws {
        let jobs = [job("paused", .paused, minutesIn: 0, done: 100), job("failed", .failed, minutesIn: 1, done: 100)]
        let snapshot = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                         isNetworkReachable: true, isWatched: { _ in false })
        #expect(snapshot.pausedCount == 1)
        #expect(snapshot.stoppedCount == 1)
        #expect(snapshot.summary == "1 download is paused. 1 download stopped, and waits for Retry in vinnyfin. Nothing new is ready to watch offline.")
        #expect(snapshot.line == "Downloads paused")
        let stopped = DownloadsSnapshot(jobs: [jobs[1]], receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                        isNetworkReachable: true, isWatched: { _ in false })
        #expect(stopped.line == "Downloads stopped")
        #expect(!stopped.isRunning)
        // One an earlier version wrote counts everything that isn't active as paused.
        var earlier = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any] ?? [:]
        earlier["pausedCount"] = nil
        let decoded = try JSONDecoder().decode(DownloadsSnapshot.self, from: JSONSerialization.data(withJSONObject: earlier))
        #expect(decoded.pausedCount == nil)
        #expect(decoded.stoppedCount == 0)
    }

    /// A download whose bytes arrive says so, though it isn't the file in hand: one queued ahead
    /// off screen, or finishing its transfers under way after another moved ahead of it.
    @Test func saysDownloadingWhileBytesArrive() {
        let jobs = [job("first", .active, minutesIn: 2, done: 450), job("second", .active, minutesIn: 1, done: 100)]
        let snapshot = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: jobs[0].id, transferring: [jobs[1].id],
                                         isHeldForPlayback: false, isNetworkReachable: true,
                                         waits: [jobs[1].id: DownloadWait.wifi.status], isWatched: { _ in false })
        #expect(snapshot.downloads.map(\.state) == [.downloading, .downloading])
    }

    @Test func saysWhyDownloadsWait() {
        let jobs = [job("a", .active, minutesIn: 0, total: nil)]
        let held = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: true,
                                     isNetworkReachable: true, isWatched: { _ in false })
        #expect(held.downloads.first?.state == .held)
        // Not begun: the listed size stands in for the one the server will give.
        #expect(held.downloads.first?.percent == 0)
        #expect(held.summary == "Downloads wait while you watch. Episode a is next. Nothing new is ready to watch offline.")
        let offline = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                        isNetworkReachable: false, isWatched: { _ in false })
        #expect(offline.downloads.first?.state == .waitingForNetwork)
        let ruled = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                      isNetworkReachable: true, waits: [jobs[0].id: DownloadWait.wifi.status], isWatched: { _ in false })
        #expect(ruled.downloads.first?.state == .waiting)
        #expect(ruled.downloads.first?.wait == "Waiting for Wi-Fi")
        #expect(ruled.summary == "Episode a is next. Waiting for Wi-Fi. Nothing new is ready to watch offline.")
        let none = DownloadsSnapshot(jobs: [], receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                     isNetworkReachable: true, isWatched: { _ in false })
        #expect(none.summary == "Nothing is downloading. Nothing new is ready to watch offline.")
        #expect(none.line == "No downloads")
        #expect(!none.isRunning)
    }

    /// The snapshot of `job` alone with `received` bytes in, taken that many seconds after the start.
    private func snapshot(of job: DownloadJob, received: Int64, status: DownloadJob.Status = .active) -> DownloadsSnapshot {
        var job = job
        job.status = status
        return DownloadsSnapshot(jobs: [job], receivedBytes: [job.id: received], downloadingJobId: job.id,
                                 isHeldForPlayback: false, isNetworkReachable: true, isWatched: { _ in false },
                                 now: Self.start.addingTimeInterval(Double(received)))
    }

    @Test func reloadsSoonForChangesAndOnceAMinuteForProgress() throws {
        let download = job("a", .active, minutesIn: 0)
        let written = snapshot(of: download, received: 100)
        let at = Self.start
        #expect(try #require(snapshot(of: download, received: 100).writeDate(after: nil, failed: nil, attemptedAt: .distantPast)) < .now)
        // Only the time it was taken differs.
        #expect(snapshot(of: download, received: 100).writeDate(after: written, failed: nil, attemptedAt: at) == nil)
        #expect(snapshot(of: download, received: 200).writeDate(after: written, failed: nil, attemptedAt: at)
            == at.addingTimeInterval(DownloadsSnapshot.progressReloadInterval))
        #expect(snapshot(of: download, received: 100, status: .paused).writeDate(after: written, failed: nil, attemptedAt: at)
            == at.addingTimeInterval(DownloadsSnapshot.changeReloadInterval))
    }

    /// A snapshot that couldn't be written isn't tried again until the downloads change, and then
    /// no sooner after the failure than after a write, so a write that keeps failing, as one to an
    /// app group the signature doesn't allow does, isn't retried over and over.
    @Test func aSnapshotThatCouldntBeWrittenWaitsForTheDownloadsToChange() {
        let download = job("a", .active, minutesIn: 0)
        let failed = snapshot(of: download, received: 100)
        let at = Self.start
        // Never written: the same downloads taken again wait, and a change is tried soon after the failure.
        #expect(snapshot(of: download, received: 100).writeDate(after: nil, failed: failed, attemptedAt: at) == nil)
        #expect(snapshot(of: download, received: 200).writeDate(after: nil, failed: failed, attemptedAt: at)
            == at.addingTimeInterval(DownloadsSnapshot.changeReloadInterval))
        // Written before: the same wait, and the reload intervals count from the failure.
        let written = snapshot(of: download, received: 50)
        #expect(snapshot(of: download, received: 100).writeDate(after: written, failed: failed, attemptedAt: at) == nil)
        #expect(snapshot(of: download, received: 200).writeDate(after: written, failed: failed, attemptedAt: at)
            == at.addingTimeInterval(DownloadsSnapshot.progressReloadInterval))
        #expect(snapshot(of: download, received: 100, status: .paused).writeDate(after: written, failed: failed, attemptedAt: at)
            == at.addingTimeInterval(DownloadsSnapshot.changeReloadInterval))
    }

    #if os(iOS) || os(macOS)
    /// The copy the widget reads keeps what each download waits for and what its server does,
    /// with the picture it adds.
    @Test func theWidgetsCopyKeepsWhatEachDownloadWaitsForAndWhatItsServerDoes() async throws {
        let jobs = [job("a", .active, minutesIn: 0, done: 10), job("b", .active, minutesIn: 1, done: 10)]
        let snapshot = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: jobs[0].id, isHeldForPlayback: false,
                                         isNetworkReachable: true, waits: [jobs[1].id: DownloadWait.wifi.status],
                                         notes: [jobs[0].id: "Server preparing 42%"], isWatched: { _ in false })
        let folder = FileManager.default.temporaryDirectory.appending(path: "WidgetSnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try await WidgetDownloads.write(snapshot, pictures: [:], to: folder)
        let read = try JSONDecoder().decode(DownloadsSnapshot.self, from: Data(contentsOf: folder.appending(path: "snapshot.json")))
        for copy in [written, read] {
            #expect(copy.downloads.map(\.note) == ["Server preparing 42%", nil])
            #expect(copy.downloads.map(\.wait) == [nil, "Waiting for Wi-Fi"])
            #expect(copy.downloads.map(\.state) == snapshot.downloads.map(\.state))
        }
    }
    #endif

    @Test func roundTripsThroughJSON() throws {
        var snapshot = DownloadsSnapshot(jobs: [job("a", .active, minutesIn: 0, done: 10)], receivedBytes: [:], downloadingJobId: nil,
                                         isHeldForPlayback: false, isNetworkReachable: true, isWatched: { _ in false })
        var title = try #require(snapshot.downloads.first?.title)
        title.hasArtwork = true
        snapshot.ready = [title]
        let decoded = try JSONDecoder().decode(DownloadsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }
}

struct IntentSummaryTests {
    private func episode(_ number: Int) -> JellyfinItem {
        Samples.item(#"{"Id":"e\#(number)","Name":"Episode \#(number)","Type":"Episode","ParentIndexNumber":2,"IndexNumber":\#(number)}"#)
    }

    @Test func saysWhichEpisodesWereQueued() {
        #expect(IntentSummaries.queued([episode(4)], of: "Test Show", asked: 3) == "Downloading S02E04 of Test Show.")
        #expect(IntentSummaries.queued([episode(4), episode(5), episode(6)], of: "Test Show", asked: 3)
            == "Downloading 3 episodes of Test Show: S02E04, S02E05, and S02E06.")
        #expect(IntentSummaries.queued([], of: "Test Show", asked: 3) == "The next 3 episodes of Test Show are already downloaded or on their way.")
        #expect(IntentSummaries.queued([], of: "Test Show", asked: 1) == "The next episode of Test Show is already downloaded or on its way.")
    }

    @Test func countsWhatPausedAndResumed() {
        #expect(IntentSummaries.paused(0) == "Nothing is downloading.")
        #expect(IntentSummaries.paused(2) == "Paused 2 downloads.")
        #expect(IntentSummaries.resumed(1) == "Resumed 1 download.")
        #expect(IntentSummaries.resumed(0) == "No downloads are paused.")
    }

    @Test func saysAMovieIsAlreadyThere() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.status = .completed
        #expect(IntentSummaries.alreadyThere(job) == "\(job.title) is already downloaded.")
        #expect(IntentSummaries.movieQueued(nil, name: "Big Test Movie", plan: .original(Samples.source), isOneOfSeveral: true)
            == "Downloading Big Test Movie: 1080p, \(DownloadEstimate.text(300_000_000)).")
        #expect(IntentSummaries.movieQueued(nil, name: "Big Test Movie", plan: .original(Samples.source), isOneOfSeveral: false)
            == "Downloading Big Test Movie: \(DownloadEstimate.text(300_000_000)).")
    }
}
#endif

struct CardFitTests {
    #if os(iOS)
    /// A 402-point iPhone, less its margins, and less the A–Z index's strip as well.
    @Test func aPhonesGridHoldsThreeColumnsDownTo340Points() {
        func columns(_ width: CGFloat) -> Int {
            CardFit.columns(in: width, minimum: Metrics.posterWidth, spacing: Metrics.gridSpacing)
        }
        #expect(columns(370) == 3)
        #expect(columns(358) == 3)
        #expect(columns(342) == 3)
        #expect(columns(340) == 3)
        #expect(columns(339) == 2)
        #expect(columns(300) == 2)
    }
    #endif

    @Test func fillsAGridWithAsManyColumnsAsFitAtTheMinimum() {
        #expect(CardFit.columns(in: 1000, minimum: 156, spacing: 14) == 5)
        #expect(CardFit.columns(in: 100, minimum: 156, spacing: 14) == 1)
        #expect(CardFit.columns(in: 1720, minimum: 230, spacing: 48) == 6)
    }

    /// The cards visible from the first's leading edge to the row's trailing one.
    private func visible(room: CGFloat, target: CGFloat, spacing: CGFloat = 14) -> Double {
        let width = CardFit.rowCardWidth(room: room, target: target, spacing: spacing)
        let whole = ((room + spacing) / (width + spacing)).rounded(.down)
        return Double(whole + (room - whole * (width + spacing)) / width)
    }

    @Test func aPhonesRowShowsThreePostersAndAPartOfAFourth() {
        // 402 and 375 points wide, the first card 16 in.
        #expect(abs(visible(room: 386, target: 104) - 3.3) < 0.01)
        #expect(abs(visible(room: 359, target: 104) - 3.3) < 0.01)
        #expect(abs(CardFit.rowCardWidth(room: 386, target: 104, spacing: 14) - 104.2) < 0.1)
    }

    @Test func aPhonesRowShowsALandscapeCardAndAPartOfTheNext() {
        #expect(abs(visible(room: 386, target: 270) - 1.3) < 0.01)
    }

    @Test func growsCardsALittleRatherThanCrowdingMoreIn() {
        // 88-point cast photos fit three and a part across a 402-point phone at 104, not four at 77.
        #expect(abs(CardFit.rowCardWidth(room: 386, target: 88, spacing: 14) - 104.2) < 0.1)
        // Posters a third over would be too many, so a 375-point phone fits them narrower.
        #expect(abs(CardFit.rowCardWidth(room: 359, target: 104, spacing: 14) - 96.1) < 0.1)
    }

    @Test func keepsCardsNearTheirWidthOnWideScreens() {
        let width = CardFit.rowCardWidth(room: 1081, target: 156, spacing: 14)
        #expect(width > 140 && width < 175)
        let cards = visible(room: 1081, target: 156)
        #expect(abs(cards - cards.rounded(.down) - 0.3) < 0.01)
    }
}

struct LibraryTitleTests {
    @Test func aListPickedByItsOrderIsRetitledInAnother() {
        #expect(LibraryGridView.title(of: HomeRows.recentMovies.list, sortedBy: "SortName") == "Movies")
        #expect(LibraryGridView.title(of: HomeRows.topShows.list, sortedBy: "DateLastContentAdded") == "Shows")
        #expect(LibraryGridView.title(of: HomeRows.genre("Drama", type: "Movie").list, sortedBy: "SortName") == "Drama Movies")
        #expect(LibraryGridView.title(of: HomeRows.somethingDifferent("Drama").list, sortedBy: "SortName")
            == "Unwatched Drama Movies and Shows")
    }

    @Test func keepsItsTitleInItsOwnOrder() {
        #expect(LibraryGridView.title(of: HomeRows.recentMovies.list, sortedBy: "DateCreated") == "Recently Added Movies")
        #expect(LibraryGridView.title(of: HomeRows.recentMovies.list, sortedBy: nil) == "Recently Added Movies")
    }

    @Test func keepsTheTitleOfAListPickedByWhatsInIt() {
        #expect(LibraryGridView.title(of: HomeRows.favorites.list, sortedBy: "DateCreated") == "Favorites")
        #expect(LibraryGridView.title(of: .titles(with: Person(id: "p", name: "Ada Vale")), sortedBy: "SortName") == "Ada Vale")
        let found = BrowseList(title: SearchView.seeAllTitle("Movies", term: "ferry"),
                               source: .items(JellyfinClient.ItemQuery(types: ["Movie"], searchTerm: "ferry")))
        #expect(LibraryGridView.title(of: found, sortedBy: "DateCreated") == "Movies Matching \u{201C}ferry\u{201D}")
    }
}

struct SearchTests {
    @Test func titlesEveryMatchOfAKindByWhatWasSearchedFor() {
        #expect(SearchView.seeAllTitle("Movies", term: "ferry") == "Movies Matching \u{201C}ferry\u{201D}")
        #expect(SearchView.seeAllTitle("Episodes", term: "the night") == "Episodes Matching \u{201C}the night\u{201D}")
    }

    @Test func neverSaysNoResultsBeforeTheSearchForWhatsTypedFinishes() {
        // The first letter, waiting out the pause before the search.
        #expect(SearchPhase(text: "p", searched: "", isSearching: false, hasResults: false, error: nil) == .searching)
        // More letters after a search that found nothing.
        #expect(SearchPhase(text: "port", searched: "p", isSearching: false, hasResults: false, error: nil) == .searching)
        // The search for what's typed waiting on the server.
        #expect(SearchPhase(text: "port", searched: "port", isSearching: true, hasResults: false, error: nil) == .searching)
        #expect(SearchPhase(text: "port ", searched: "port", isSearching: false, hasResults: false, error: nil) == .noResults)
    }

    @Test func keepsWhatWasFoundOnScreenWhileTheNextSearchRuns() {
        #expect(SearchPhase(text: "por", searched: "po", isSearching: true, hasResults: true, error: nil) == .results)
        #expect(SearchPhase(text: "port", searched: "port", isSearching: false, hasResults: true, error: nil) == .results)
    }

    @Test func saysASearchFailedOnlyForWhatsTyped() {
        #expect(SearchPhase(text: "port", searched: "port", isSearching: false, hasResults: false, error: "Offline") == .failed("Offline"))
        #expect(SearchPhase(text: "porta", searched: "port", isSearching: false, hasResults: false, error: "Offline") == .searching)
        #expect(SearchPhase(text: "port", searched: "port", isSearching: true, hasResults: false, error: "Offline") == .searching)
    }

    @Test func promptsWithNothingTyped() {
        #expect(SearchPhase(text: "  ", searched: "port", isSearching: false, hasResults: true, error: nil) == .prompt)
    }

    @Test func numbersAnEpisodeShortForItsSearchCard() {
        #expect(Samples.item(#"{"Id":"e","Name":"The Night Ferry","Type":"Episode","ParentIndexNumber":1,"IndexNumber":1}"#).shortEpisodeCode
            == "S1, E1")
        #expect(Samples.item(#"{"Id":"e","Name":"Two","Type":"Episode","ParentIndexNumber":2,"IndexNumber":2,"IndexNumberEnd":3}"#).shortEpisodeCode
            == "S2, E2–3")
        #expect(Samples.item(#"{"Id":"e","Name":"Behind the Scenes","Type":"Episode","ParentIndexNumber":0,"IndexNumber":1}"#).shortEpisodeCode
            == "Specials, E1")
        #expect(Samples.movie.shortEpisodeCode == nil)
    }

    // MARK: Hints

    private static func hints(_ json: String) throws -> [SearchHint] {
        try JSONDecoder().decode(SearchHintsPage.self, from: Data(json.utf8)).searchHints
    }

    @Test func sortsTheServersHintsIntoPeopleGenresAndCollections() throws {
        let hints = try Self.hints("""
        {"SearchHints":[
          {"Id":"p1","Name":"Ada Vale","Type":"Person","PrimaryImageTag":"face"},
          {"Id":"g1","Name":"Western","Type":"Genre","PrimaryImageTag":"collage"},
          {"Id":"b1","Name":"The Vale Collection","Type":"BoxSet","PrimaryImageTag":"poster","ProductionYear":2019},
          {"Id":"s1","Name":"Studio Vale","Type":"Studio"},
          {"Id":"g2","Name":"Western","Type":"Genre"},
          {"ItemId":"p2","Name":"Bo Vale","Type":"Person"}
        ],"TotalRecordCount":6}
        """)
        let results = SearchResults(hints: hints)
        #expect(results.people == [Person(id: "p1", name: "Ada Vale", type: "Person", primaryImageTag: "face"),
                                   Person(id: "p2", name: "Bo Vale", type: "Person")])
        #expect(results.genres == ["Western"])
        #expect(results.collections.map(\.id) == ["b1"])
        let collection = try #require(results.collections.first)
        #expect(collection.isCollection)
        #expect(collection.primaryImageTag == "poster")
        #expect(collection.productionYear == 2019)
        #expect(!results.isEmpty)
        #expect(results.summary == "1 collection, 2 people, and 1 genre")
        #expect(SearchResults().isEmpty)
        #expect(SearchResults().summary == "No results")
    }

    @Test func leadsWithTheTitleNamedOrStartingWithWhatWasTyped() {
        let starfall = Samples.item(#"{"Id":"e9","Name":"Starfall","Type":"Episode","SeriesName":"Starfall Station"}"#)
        let station = Samples.item(#"{"Id":"s3","Name":"Starfall Station","Type":"Series"}"#)
        let ferry = Samples.item(#"{"Id":"m3","Name":"The Last Ferry to Ilsa","Type":"Movie"}"#)
        let signal = Samples.item(#"{"Id":"m4","Name":"Signal Over Kestrel Bay","Type":"Movie"}"#)
        let found = SearchResults(movies: [ferry, signal], shows: [station], episodes: [starfall])
        // A show starting with it, ahead of the episode of the same and movies merely containing it.
        #expect(found.topResult(for: "st") == station)
        #expect(found.sections(for: "st") == [.shows, .episodes, .movies])
        // Named exactly, the episode leads.
        #expect(found.topResult(for: "Starfall") == starfall)
        // A word of the name starting with it.
        #expect(found.topResult(for: "kestrel") == signal)
        #expect(found.sections(for: "kestrel") == [.movies, .shows, .episodes])
        // Contained mid-word is no top result.
        #expect(found.topResult(for: "estre") == nil)
        let copperline = Samples.item(#"{"Id":"m2","Name":"Copperline","Type":"Movie","ProductionYear":2019}"#)
        #expect(SearchResults(movies: [copperline]).topResult(for: "copperline (2019)") == copperline)
    }

    @Test func putsAGenreOrPersonNamedExactlyAboveLooseTitles() throws {
        let hints = try Self.hints(#"{"SearchHints":[{"Id":"g","Name":"Western","Type":"Genre"},{"Id":"p","Name":"Wes Hart","Type":"Person"}]}"#)
        let loose = Samples.item(#"{"Id":"m","Name":"Midwestern Nights","Type":"Movie"}"#)
        let found = SearchResults(movies: [loose], hints: hints)
        #expect(found.sections(for: "western") == [.genres, .movies, .people])
        #expect(found.sections(for: "wes") == [.people, .genres, .movies])
        #expect(found.topResult(for: "western") == nil)
    }

    @Test func matchesIgnoringCaseAccentsAndPunctuationAtTheEnds() {
        #expect(SearchMatch(name: "Amélie", term: "amelie") == .exact)
        #expect(SearchMatch(name: "Port Ellery", term: "  port  ") == .prefix)
        #expect(SearchMatch(name: "The Long Field", term: "field!") == .wordPrefix)
        #expect(SearchMatch(name: "Copperline", term: "perl") == .contains)
        #expect(SearchMatch(name: "Copperline", term: "zinc") == .none)
        #expect(SearchMatch(name: "Copperline", term: "") == .none)
    }

    // MARK: Did you mean

    private static let names = ["Copperline", "Port Ellery", "The Last Ferry to Ilsa", "Starfall Station", "Western", "Drama", "Thriller"]

    @Test func suggestsTheNameALetterOrTwoOff() {
        #expect(DidYouMean.suggestion(for: "coperline", among: Self.names) == "Copperline")
        #expect(DidYouMean.suggestion(for: "Coppreline", among: Self.names) == "Copperline")
        #expect(DidYouMean.suggestion(for: "westrn", among: Self.names) == "Western")
        #expect(DidYouMean.suggestion(for: "port elery", among: Self.names) == "Port Ellery")
        // The start of a long name.
        #expect(DidYouMean.suggestion(for: "the last fery", among: Self.names) == "The Last Ferry to Ilsa")
        // Swapped letters count once.
        #expect(DidYouMean.suggestion(for: "dramma", among: Self.names) == "Drama")
        #expect(DidYouMean.suggestion(for: "darma", among: Self.names) == "Drama")
    }

    @Test func suggestsNothingTooFarOffOrTooShort() {
        #expect(DidYouMean.suggestion(for: "zebra crossing", among: Self.names) == nil)
        // Up to five letters, one letter off at most.
        #expect(DidYouMean.suggestion(for: "drxmx", among: Self.names) == nil)
        #expect(DidYouMean.suggestion(for: "dr", among: Self.names) == nil)
        #expect(DidYouMean.suggestion(for: "copperline", among: Self.names) == nil)
        #expect(DidYouMean.suggestion(for: "coperline", among: []) == nil)
    }

    @Test func countsLettersAddedTakenAwayChangedAndSwapped() {
        func distance(_ left: String, _ right: String, limit: Int = 5) -> Int {
            DidYouMean.editDistance(Array(left), Array(right), limit: limit)
        }
        #expect(distance("teh", "the") == 1)
        #expect(distance("kitten", "sitting") == 3)
        #expect(distance("", "abc") == 3)
        #expect(distance("same", "same") == 0)
        // Past the limit, it stops counting.
        #expect(distance("kitten", "sitting", limit: 1) == 2)
        #expect(distance("a", "abcdefgh", limit: 2) == 3)
    }

    // MARK: Recent searches

    @Test func keepsRecentSearchesNewestFirstOnceEach() {
        var terms: [String] = []
        for term in ["port", "Western", " copperline ", "PORT", ""] {
            terms = RecentSearches.adding(term, to: terms)
        }
        #expect(terms == ["PORT", "copperline", "Western"])
        for number in 1...10 { terms = RecentSearches.adding("term \(number)", to: terms) }
        #expect(terms.count == RecentSearches.limit)
        #expect(terms.first == "term 10")
    }

    @Test func keepsRecentSearchesForEachSignIn() throws {
        let suite = "RecentSearchTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alex = RecentSearches(defaults: defaults, serverId: "den", userId: "alex")
        let sam = RecentSearches(defaults: defaults, serverId: "den", userId: "sam")
        alex.save(["port", "western"])
        #expect(alex.load() == ["port", "western"])
        #expect(sam.load().isEmpty)
        #expect(RecentSearches(defaults: defaults, serverId: "den", userId: "alex").load() == ["port", "western"])
    }
}

struct GenreBrowsingTests {
    @Test func aGenresListIsItsMoviesAndShowsBestRatedFirst() throws {
        let list = BrowseList.genre("Western")
        #expect(list.title == "Western")
        #expect(list.style == .poster)
        #expect(list.refinementsKey == nil)
        guard case .items(let query) = list.source else { throw ListError.notAQuery }
        #expect(query.types == ["Movie", "Series"])
        #expect(query.genres == ["Western"])
        #expect(query.sortBy == "CommunityRating")
        #expect(!query.ascending)
        #expect(query.excludeIds.isEmpty)
        #expect(list.symbol == "theatermasks")
    }

    @Test func aGenresOtherTitlesLeaveOutTheOneShowing() throws {
        guard case .items(let query) = BrowseList.genre("Western", excluding: "m2").source else { throw ListError.notAQuery }
        #expect(query.genres == ["Western"])
        #expect(query.excludeIds == ["m2"])
    }

    @Test func aGenresListKeepsItsNameInAnyOrder() {
        #expect(LibraryGridView.title(of: .genre("Western"), sortedBy: "SortName") == "Western")
        #expect(LibraryGridView.title(of: .genre("Western"), sortedBy: "Random") == "Western")
        // Home's genre rows are titled for their kind as well, which another order keeps.
        #expect(LibraryGridView.title(of: HomeRows.genre("Drama", type: "Movie").list, sortedBy: "SortName") == "Drama Movies")
        // A list picked by its order, shuffled, is every title of its kind.
        #expect(LibraryGridView.title(of: HomeRows.topMovies.list, sortedBy: "Random") == "Movies")
    }

    @Test func tilesTheGenresThatHaveTitles() {
        let found = [
            Samples.item(#"{"Id":"g1","Name":"Drama","Type":"Genre","MovieCount":5,"SeriesCount":2}"#),
            Samples.item(#"{"Id":"g2","Name":"Food","Type":"Genre","SeriesCount":1}"#),
            Samples.item(#"{"Id":"g3","Name":"Empty","Type":"Genre","MovieCount":0,"SeriesCount":0}"#),
        ]
        #expect(GenreTiles.genres(from: found) == [GenreTiles.Genre(name: "Drama", count: 7), GenreTiles.Genre(name: "Food", count: 1)])
        #expect(GenreTile.count(1) == "1 title")
        #expect(GenreTile.count(7) == "7 titles")
    }

    @Test func picksATilesPictureNoOtherTileShows() {
        let pictured = Samples.item(#"{"Id":"a","Name":"A","Type":"Movie","BackdropImageTags":["b"]}"#)
        let unpictured = Samples.item(#"{"Id":"b","Name":"B","Type":"Movie","BackdropImageTags":[]}"#)
        let other = Samples.item(#"{"Id":"c","Name":"C","Type":"Series","BackdropImageTags":["c"]}"#)
        #expect(GenreTiles.pick(from: [unpictured, pictured, other], taken: []) == pictured)
        #expect(GenreTiles.pick(from: [unpictured, pictured, other], taken: ["a"]) == other)
        // Every picture taken, the best one shows again rather than none.
        #expect(GenreTiles.pick(from: [pictured, other], taken: ["a", "c"]) == pictured)
        #expect(GenreTiles.pick(from: [unpictured], taken: []) == nil)
    }

    @Test func aLibraryListsItsOwnKindOfTitles() throws {
        func list(_ type: String?) throws -> (BrowseList, JellyfinClient.ItemQuery) {
            var library = JellyfinItem(id: "lib", name: "Library", type: "CollectionFolder")
            library.collectionType = type
            let list = BrowseList.library(library)
            guard case .items(let query) = list.source else { throw ListError.notAQuery }
            return (list, query)
        }
        let (homeVideos, homeQuery) = try list("homevideos")
        #expect(homeQuery.types == ["Video"])
        #expect(homeQuery.parentId == "lib")
        #expect(homeVideos.style == .landscape)
        #expect(homeVideos.symbol == "video")
        #expect(try list("musicvideos").1.types == ["MusicVideo"])
        #expect(try list("movies").1.types == ["Movie"])
        #expect(try list("movies").0.style == .poster)
        #expect(try list("tvshows").1.types == ["Series"])
        #expect(try list(nil).1.types == ["Movie", "Series", "Video", "MusicVideo"])
        #expect(try list("mixed").0.style == .poster)
        #expect(LibraryGridView.title(of: homeVideos, sortedBy: "DateCreated") == "Library")
    }

    @Test func showsLibrariesOnSearchWhenTheTabsDontReachEach() {
        func library(_ id: String, _ type: String?) -> JellyfinItem {
            var library = JellyfinItem(id: id, name: id, type: "CollectionFolder")
            library.collectionType = type
            return library
        }
        let movies = library("Movies", "movies"), shows = library("Shows", "tvshows")
        #expect(LibraryShortcuts.shown([movies, shows]).isEmpty)
        #expect(LibraryShortcuts.shown([movies]).isEmpty)
        let home = library("Home Videos", "homevideos")
        #expect(LibraryShortcuts.shown([movies, shows, home]).map(\.id) == ["Movies", "Shows", "Home Videos"])
        #expect(LibraryShortcuts.shown([movies, library("Kids", "movies")]).count == 2)
        #expect(LibraryShortcuts.shown([library("Everything", nil)]).count == 1)
    }

    @Test func saysWhatTheTopResultIs() {
        #expect(TopResultCard.detail(of: Samples.item(#"{"Id":"m","Name":"Copperline","Type":"Movie","ProductionYear":2019}"#)) == "Movie · 2019")
        #expect(TopResultCard.detail(of: Samples.item(#"{"Id":"s","Name":"Port Ellery","Type":"Series"}"#)) == "Show")
        #expect(TopResultCard.detail(of: Samples.item(
            #"{"Id":"e","Name":"Low Tide","Type":"Episode","SeriesName":"Port Ellery","ParentIndexNumber":1,"IndexNumber":2}"#))
            == "Episode · Port Ellery · S1, E2")
    }

    private enum ListError: Error { case notAQuery }
}

struct LibraryRefinementTests {
    private static let movies: JellyfinClient.ItemQuery = {
        guard case .items(let query) = BrowseList.movies.source else { return .init() }
        return query
    }()

    private static func library(_ id: String, _ name: String) -> JellyfinItem {
        JellyfinItem(id: id, name: name, type: "CollectionFolder")
    }

    @Test func startsFromTheListsOwnOrderWithNoFilters() {
        let refinements = LibraryRefinements(of: Self.movies)
        #expect(refinements.sort == .name)
        #expect(refinements.ascending)
        #expect(!refinements.isFiltered)
        #expect(refinements.chips(libraries: []).isEmpty)
        #expect(refinements.applied(to: Self.movies) == Self.movies)
        #expect(LibraryRefinements(of: HomeRows.recentMovies.list.source.query!).sort == .dateAdded)
        #expect(LibraryRefinements(of: HomeRows.recentMovies.list.source.query!).ascending == false)
    }

    @Test func aChipForEachFilterTakesItAway() {
        var refinements = LibraryRefinements(sort: .name, ascending: true, filter: .unwatched, genres: ["Drama", "Thriller"],
                                             libraryId: "kids")
        let libraries = [Self.library("kids", "Kids"), Self.library("films", "Films")]
        #expect(refinements.chips(libraries: libraries) == [.filter(.unwatched), .genre("Drama"), .genre("Thriller"),
                                                             .library(id: "kids", name: "Kids")])
        #expect(refinements.chips(libraries: libraries).map(\.label) == ["Unwatched", "Drama", "Thriller", "Kids"])
        #expect(refinements.filterSummary(libraries: libraries) == "Unwatched, Drama or Thriller, and Kids")
        #expect(refinements.filterSubtitle(libraries: libraries) == "Unwatched · Drama or Thriller · Kids")

        refinements.remove(.genre("Drama"))
        #expect(refinements.genres == ["Thriller"])
        refinements.remove(.filter(.unwatched))
        #expect(refinements.filter == .all)
        refinements.remove(.library(id: "kids", name: "Kids"))
        #expect(refinements.libraryId == nil)
        #expect(refinements.chips(libraries: libraries) == [.genre("Thriller")])
        #expect(refinements.isFiltered)
    }

    @Test func clearingTakesEveryFilterAwayAndLeavesTheSort() {
        var refinements = LibraryRefinements(sort: .rating, ascending: true, filter: .favorites, genres: ["Drama"], libraryId: "kids")
        refinements.clearFilters()
        #expect(!refinements.isFiltered)
        #expect(refinements.chips(libraries: []).isEmpty)
        #expect(refinements.sort == .rating)
        #expect(refinements.ascending)
        // A library that can't be named still has a chip to take it away.
        #expect(LibraryRefinements(sort: .name, ascending: true, libraryId: "gone").chips(libraries: []) == [.library(id: "gone", name: "Library")])
    }

    @Test func picksSeveralGenresAndPutsThemBack() {
        var refinements = LibraryRefinements(of: Self.movies)
        refinements.toggle(genre: "Drama")
        refinements.toggle(genre: "Western")
        #expect(refinements.genres == ["Drama", "Western"])
        #expect(refinements.applied(to: Self.movies).genres == ["Drama", "Western"])
        #expect(refinements.filterSummary(libraries: []) == "Drama or Western")
        refinements.toggle(genre: "Drama")
        #expect(refinements.genres == ["Western"])
    }

    @Test func refinesTheQueryButLeavesWhatTheListFixes() {
        var refinements = LibraryRefinements(of: Self.movies)
        refinements.choose(.dateAdded)
        refinements.filter = .favorites
        refinements.libraryId = "kids"
        let query = refinements.applied(to: Self.movies)
        #expect(query.sortBy == "DateCreated")
        #expect(!query.ascending)
        #expect(query.isFavorite == true)
        #expect(query.isPlayed == nil)
        #expect(query.parentId == "kids")

        // Unwatched Favorites fixes watch state; a genre list fixes its genre; a library list its library.
        let unwatchedFavorites = HomeRows.unwatchedFavorites.list.source.query!
        refinements.filter = .all
        #expect(refinements.applied(to: unwatchedFavorites).isPlayed == false)
        #expect(refinements.applied(to: unwatchedFavorites).isFavorite == true)
        refinements.genres = ["Drama"]
        #expect(refinements.applied(to: BrowseList.genre("Western").source.query!).genres == ["Western"])
        var library = JellyfinItem(id: "home", name: "Home Videos", type: "CollectionFolder")
        library.collectionType = "homevideos"
        #expect(refinements.applied(to: BrowseList.library(library).source.query!).parentId == "home")
    }

    @Test func eachSortGoesItsUsualWayAndTurnsTheOther() {
        var refinements = LibraryRefinements(of: Self.movies)
        refinements.choose(.rating)
        #expect(refinements.sortSummary == "Rating, Highest First")
        refinements.ascending.toggle()
        #expect(refinements.sortSummary == "Rating, Lowest First")
        #expect(refinements.applied(to: Self.movies).ascending)
        refinements.choose(.name)
        #expect(refinements.sortSummary == "Name, A to Z")
        refinements.ascending = false
        #expect(refinements.sortSummary == "Name, Z to A")
        refinements.choose(.dateAdded)
        #expect(refinements.sortSummary == "Date Added, Newest First")
        #expect(LibraryGridView.Sort.lastPlayed.direction(ascending: false) == "Latest First")
        #expect(LibraryGridView.Sort.releaseDate.direction(ascending: true) == "Oldest First")
        #expect(LibraryGridView.Sort.dateAdded.serverField(for: ["Series"]) == "DateLastContentAdded")
    }

    @Test func aRandomSortShufflesTheQueryBySeed() {
        var refinements = LibraryRefinements(of: Self.movies)
        refinements.filter = .unwatched
        refinements.choose(.random)
        #expect(refinements.sortSummary == "Random")
        guard case .shuffled(let query, let seed) = refinements.source(for: Self.movies, seed: 7) else {
            Issue.record("A random sort isn't shuffled")
            return
        }
        #expect(seed == 7)
        #expect(query.isPlayed == false)
        // The list's own order stays, for paging the shuffled ids.
        #expect(query.sortBy == "SortName")
        refinements.choose(.name)
        #expect(refinements.source(for: Self.movies, seed: 7) == .items(refinements.applied(to: Self.movies)))
    }

    @Test func remembersEachTabsSortAndFilterForEachSignIn() throws {
        let suite = "LibraryMemoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let movies = LibraryMemory(defaults: defaults, list: "movies", serverId: "den", userId: "alex")
        #expect(movies.load() == nil)
        var refinements = LibraryRefinements(of: Self.movies)
        refinements.choose(.random)
        refinements.genres = ["Drama", "Thriller"]
        refinements.filter = .unwatched
        movies.save(refinements)
        #expect(LibraryMemory(defaults: defaults, list: "movies", serverId: "den", userId: "alex").load() == refinements)
        #expect(LibraryMemory(defaults: defaults, list: "shows", serverId: "den", userId: "alex").load() == nil)
        #expect(LibraryMemory(defaults: defaults, list: "movies", serverId: "den", userId: "sam").load() == nil)
        #expect(LibraryMemory(defaults: defaults, list: "movies", serverId: "attic", userId: "alex").load() == nil)
        // Only the tabs' lists are kept.
        #expect(BrowseList.movies.refinementsKey == "movies")
        #expect(BrowseList.shows.refinementsKey == "shows")
        #expect(HomeRows.recentMovies.list.refinementsKey == nil)
    }
}

struct ShuffleOrderTests {
    private static let ids = (1...200).map { "id\($0)" }

    @Test func theSameSeedGivesTheSameOrder() {
        let once = ShuffleOrder.sorted(Self.ids, seed: 42)
        #expect(once == ShuffleOrder.sorted(Self.ids.reversed(), seed: 42))
        #expect(Set(once) == Set(Self.ids))
        #expect(once != Self.ids)
        #expect(once != ShuffleOrder.sorted(Self.ids, seed: 43))
    }

    @Test func titlesAddedOrGoneLeaveTheOthersOrderAlone() {
        let before = ShuffleOrder.sorted(Self.ids, seed: 9)
        let after = ShuffleOrder.sorted(Self.ids.filter { $0 != "id50" } + ["new"], seed: 9)
        #expect(after.filter { $0 != "new" } == before.filter { $0 != "id50" })
    }

    @Test func mergesTheNewestMoviesAndShowsByWhenEachWasAdded() {
        let day = { (offset: Double) in Date(timeIntervalSince1970: 1_800_000_000 + offset * 86_400) }
        let movie = JellyfinItem(id: "m", name: "Movie", type: "Movie")
        let show = JellyfinItem(id: "s", name: "Show", type: "Series")
        let older = JellyfinItem(id: "o", name: "Older", type: "Movie")
        let undated = JellyfinItem(id: "u", name: "Undated", type: "Movie")
        let merged = JellyfinClient.newestFirst([(older, day(1)), (undated, nil), (movie, day(3)), (show, day(5))], limit: 3)
        #expect(merged.map(\.id) == ["s", "m", "o"])
        #expect(JellyfinClient.newestFirst([(undated, nil), (older, nil)], limit: 5).map(\.id) == ["u", "o"])
    }
}

private extension JellyfinClient.ItemSource {
    var query: JellyfinClient.ItemQuery? {
        if case .items(let query) = self { query } else { nil }
    }
}
