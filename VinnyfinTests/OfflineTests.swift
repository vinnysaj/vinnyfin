import Foundation
import ImageIO
import Nuke
import SwiftUI
import Synchronization
import Testing
@testable import vinnyfin

/// Sign-ins to test with: two people on one server, each with their own token.
private enum Offline {
    static let alex = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "home", serverName: "Home",
                                           userId: "u1", userName: "Alex")
    static let sam = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "home", serverName: "Home",
                                          userId: "u2", userName: "Sam")

    static func session(_ account: AccountStore.Account, token: String) -> ServerSession {
        ServerSession(client: JellyfinClient(serverURL: account.serverURL, deviceId: "device", deviceName: "Test", token: token),
                      account: account)
    }

    static func directory() -> URL {
        URL.temporaryDirectory.appending(path: "OfflineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func item(_ id: String, _ name: String, type: String = "Movie", series: String? = nil) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: name, type: type)
        item.seriesName = series
        if series != nil {
            item.seriesId = "series-" + (series ?? "")
            item.parentIndexNumber = 1
            item.indexNumber = 1
        }
        return item
    }

    /// Waits until `condition` holds, up to `limit`.
    @MainActor
    static func until(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Counts the questions put to a server, and answers them as told.
private final class FakeServer: Sendable {
    /// How each question is answered, in turn; the last again for the rest.
    enum Answer: Sendable {
        case answers
        case fails(any Error)
        case neverAnswers
    }

    private let state: Mutex<(answers: [Answer], asked: Int)>

    init(_ answers: Answer...) {
        state = Mutex((answers, 0))
    }

    var asked: Int { state.withLock { $0.asked } }

    func answer(_ answers: Answer...) {
        state.withLock { $0.answers = answers }
    }

    var ask: ServerReachability.Ask {
        { _, _ in
            let answer = self.state.withLock { state -> Answer in
                state.asked += 1
                return state.answers.count > 1 ? state.answers.removeFirst() : state.answers[0]
            }
            switch answer {
            case .answers: return
            case .fails(let error): throw error
            case .neverAnswers: try await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

@MainActor
struct ServerReachabilityTests {
    private func reachability(_ server: FakeServer, timeLimit: Duration = .seconds(4), retryInterval: Duration = .seconds(15),
                              networkChanges: AsyncStream<Void> = AsyncStream { _ in }) -> ServerReachability {
        ServerReachability(timeLimit: timeLimit, retryInterval: retryInterval, networkChanges: { networkChanges }, ask: server.ask)
    }

    @Test func asksForThreeToFiveSecondsAtMost() {
        #expect(ServerReachability.timeLimit >= .seconds(3))
        #expect(ServerReachability.timeLimit <= .seconds(5))
    }

    @Test func takesTheServerToAnswerUntilItHasBeenAsked() {
        let reachability = reachability(FakeServer(.answers))
        #expect(reachability.state == .unknown)
        #expect(!reachability.isOutOfReach)
    }

    @Test func aServerThatAnswersIsReachable() async {
        let server = FakeServer(.answers)
        let reachability = reachability(server)
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        #expect(await Offline.until { reachability.state == .reachable })
        #expect(server.asked == 1)
        #expect(reachability.signIn == Offline.alex.tokenKey)
    }

    @Test func aServerThatNeverAnswersIsOutOfReachOnceTheTimeLimitPasses() async {
        let reachability = reachability(FakeServer(.neverAnswers), timeLimit: .milliseconds(300))
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        // Still asking, and still taken to answer, before the limit.
        #expect(await Offline.until { reachability.isChecking })
        #expect(reachability.state == .unknown)
        #expect(await Offline.until { reachability.isOutOfReach })
        let waited = clock.now - started
        #expect(waited >= .milliseconds(250))
        #expect(waited < .seconds(3))
        #expect(reachability.state == .outOfReach(.noAnswer))
        #expect(!reachability.isChecking)
    }

    @Test func aRefusedConnectionIsOutOfReachAtOnce() async {
        let reachability = reachability(FakeServer(.fails(URLError(.cannotConnectToHost))), timeLimit: .seconds(30))
        let clock = ContinuousClock()
        let started = clock.now
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        #expect(await Offline.until { reachability.isOutOfReach })
        #expect(clock.now - started < .seconds(2))
        #expect(reachability.state == .outOfReach(.noAnswer))
    }

    @Test func saysWhyTheServerIsOutOfReach() {
        #expect(ServerReachability.absence(for: URLError(.notConnectedToInternet)) == .deviceOffline)
        #expect(ServerReachability.absence(for: URLError(.timedOut)) == .noAnswer)
        #expect(ServerReachability.absence(for: URLError(.cannotFindHost)) == .noAnswer)
        // A hotel network's sign-in page, or another Jellyfin server at the address.
        #expect(ServerReachability.absence(for: JellyfinError.notJellyfin(Offline.alex.serverURL)) == .somethingElseAnswers)
        #expect(ServerReachability.absence(for: ServerReachability.ServerMismatch()) == .somethingElseAnswers)
        // A proxy in front of a server that's down.
        #expect(ServerReachability.absence(for: JellyfinError.http(status: 502, body: "")) == .failing(status: 502))
    }

    @Test func comesBackWhenTheServerAnswersAgain() async {
        let server = FakeServer(.fails(URLError(.timedOut)), .fails(URLError(.timedOut)), .answers)
        let reachability = reachability(server, retryInterval: .milliseconds(50))
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        #expect(await Offline.until { reachability.isOutOfReach })
        #expect(await Offline.until { reachability.state == .reachable })
        #expect(server.asked == 3)
        // Answering, it isn't asked again until something happens.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(server.asked == 3)
    }

    @Test func tellsTheImagesWhichServerIsOutOfReachAndWhenItAnswers() async {
        final class Told {
            var servers: [URL?] = []
        }
        let server = FakeServer(.fails(URLError(.timedOut)), .answers)
        let reachability = reachability(server, retryInterval: .milliseconds(50))
        let told = Told()
        reachability.outOfReachChanged = { told.servers.append($0) }
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        #expect(await Offline.until { reachability.state == .reachable })
        #expect(told.servers == [Offline.alex.serverURL, nil])
    }

    @Test func asksAgainWhenTheNetworkChanges() async {
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        let server = FakeServer(.answers)
        let reachability = reachability(server, networkChanges: changes)
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        #expect(await Offline.until { reachability.state == .reachable })
        // Out of the house: the server at home no longer answers.
        server.answer(.fails(URLError(.timedOut)))
        change.yield()
        #expect(await Offline.until { reachability.isOutOfReach })
        server.answer(.answers)
        change.yield()
        #expect(await Offline.until { reachability.state == .reachable })
    }

    @Test func tryAgainAsksOnceForEveryoneWaiting() async {
        let server = FakeServer(.fails(URLError(.timedOut)))
        let reachability = reachability(server, timeLimit: .milliseconds(200))
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        #expect(await Offline.until { reachability.isOutOfReach })
        server.answer(.neverAnswers)
        let before = server.asked
        async let first: Void = reachability.check()
        async let second: Void = reachability.check()
        _ = await (first, second)
        #expect(server.asked == before + 1)
    }

    @Test func anotherSignInIsAskedAfresh() async {
        let server = FakeServer(.fails(URLError(.timedOut)))
        let reachability = reachability(server)
        let alex = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        #expect(await Offline.until { reachability.isOutOfReach })
        alex.cancel()
        server.answer(.neverAnswers)
        let sam = Task { await reachability.follow(Offline.session(Offline.sam, token: "s")) }
        defer { sam.cancel() }
        #expect(await Offline.until { reachability.signIn == Offline.sam.tokenKey })
        // What was known of Alex's says nothing of Sam's.
        #expect(reachability.state == .unknown)
        // Signed out, nothing's known.
        sam.cancel()
        await reachability.follow(nil)
        #expect(reachability.signIn == nil)
        #expect(reachability.state == .unknown)
    }
}

struct HomeCacheTests {
    private static let snapshot = HomeSnapshot(
        rows: [HomeRows.continueWatching, HomeRows.recentMovies, HomeRows.genre("Drama", type: "Movie")],
        items: [HomeRows.continueWatching.id: [Offline.item("e1", "Dead Reckoning", type: "Episode", series: "Starfall Station")],
                HomeRows.recentMovies.id: [Offline.item("m1", "Amber Cartographers")]],
        givenWay: [], truncated: [HomeRows.recentMovies.id],
        featured: [Offline.item("m2", "Halden Ridge")], featuredEpisodes: [:],
        randomSeed: 42, savedAt: Date(timeIntervalSince1970: 1_000_000)
    )

    @Test func opensWhatTheSameSignInSaved() throws {
        let directory = Offline.directory()
        let alex = try #require(HomeCache(Offline.session(Offline.alex, token: "alex-token"), directory: directory))
        try alex.write(Self.snapshot)
        let reopened = try #require(HomeCache(Offline.session(Offline.alex, token: "alex-token"), directory: directory))
        #expect(reopened.load() == Self.snapshot)
    }

    @Test func anotherSignInCantReadIt() throws {
        let directory = Offline.directory()
        let alex = try #require(HomeCache(Offline.session(Offline.alex, token: "alex-token"), directory: directory))
        try alex.write(Self.snapshot)
        let sam = try #require(HomeCache(Offline.session(Offline.sam, token: "sam-token"), directory: directory))
        #expect(sam.file != alex.file)
        #expect(sam.load() == nil)
        // Not even in Sam's place: it's sealed with Alex's token.
        try FileManager.default.copyItem(at: alex.file, to: sam.file)
        #expect(sam.load() == nil)
        // Nor does the file say whose it is.
        #expect(!alex.file.lastPathComponent.contains("u1"))
        #expect(try Data(contentsOf: alex.file).range(of: Data("Amber".utf8)) == nil)
    }

    @Test func aSignInWithANewTokenStartsAfresh() throws {
        let directory = Offline.directory()
        try #require(HomeCache(Offline.session(Offline.alex, token: "old"), directory: directory)).write(Self.snapshot)
        #expect(try #require(HomeCache(Offline.session(Offline.alex, token: "new"), directory: directory)).load() == nil)
    }

    @Test func noTokenNoCache() {
        let session = ServerSession(client: JellyfinClient(serverURL: Offline.alex.serverURL, deviceId: "d", deviceName: "Test"),
                                    account: Offline.alex)
        #expect(HomeCache(session, directory: Offline.directory()) == nil)
    }

    @Test func signingOutDropsItAndKeepsTheOthers() throws {
        let directory = Offline.directory()
        let alex = try #require(HomeCache(Offline.session(Offline.alex, token: "alex"), directory: directory))
        let sam = try #require(HomeCache(Offline.session(Offline.sam, token: "sam"), directory: directory))
        try alex.write(Self.snapshot)
        try sam.write(Self.snapshot)
        let defaults = try #require(UserDefaults(suiteName: "HomeCacheTests-\(UUID().uuidString)"))
        defaults.set(try JSONEncoder().encode(Offline.alex), forKey: "account")
        defaults.set(try JSONEncoder().encode([Offline.alex, Offline.sam]), forKey: "accounts")
        let tokens = Mutex([Offline.alex.tokenKey: "alex", Offline.sam.tokenKey: "sam"])
        let accounts = AccountStore(defaults: defaults, tokens: AccountStore.TokenStore(
            read: { key in tokens.withLock { $0[key] } },
            write: { token, key in tokens.withLock { $0[key] = token } },
            delete: { key in _ = tokens.withLock { $0.removeValue(forKey: key) } }
        )) { _ in }
        accounts.forgetting = { HomeCache.drop(for: $0, in: directory) }
        accounts.signOut()
        #expect(!FileManager.default.fileExists(atPath: alex.file.path))
        #expect(sam.load() == Self.snapshot)
    }

    @Test func onlyTheSignInsKeptKeepTheirs() async throws {
        let directory = Offline.directory()
        let alex = try #require(HomeCache(Offline.session(Offline.alex, token: "alex"), directory: directory))
        let sam = try #require(HomeCache(Offline.session(Offline.sam, token: "sam"), directory: directory))
        try alex.write(Self.snapshot)
        try sam.write(Self.snapshot)
        HomeCache.keepOnly([Offline.alex], in: directory)
        // After the sweep: deletions wait for what was asked of the caches before them.
        HomeCache.drop(for: AccountStore.Account(serverURL: Offline.alex.serverURL, serverId: "elsewhere", userId: "x", userName: "x"),
                       in: directory)
        #expect(!FileManager.default.fileExists(atPath: sam.file.path))
        #expect(alex.load() == Self.snapshot)
    }

    @MainActor
    @Test func homeDrawsWhatItSavedForTheSignInWhileTheServerIsOutOfReach() async throws {
        let directory = Offline.directory()
        let defaults = try #require(UserDefaults(suiteName: "HomeCacheTests-\(UUID().uuidString)"))
        try #require(HomeCache(Offline.session(Offline.alex, token: "alex"), directory: directory)).write(Self.snapshot)

        let feed = HomeFeed(defaults: defaults, cacheDirectory: directory)
        await feed.load(session: Offline.session(Offline.alex, token: "alex"), isServerOutOfReach: true)
        #expect(feed.isOffline)
        #expect(feed.rows == Self.snapshot.rows)
        #expect(feed.featured == Self.snapshot.featured)
        #expect(feed.items == Self.snapshot.items)
        #expect(feed.truncated == Self.snapshot.truncated)
        // No stand-ins, and nothing that couldn't load: the rows saved with titles, and no others.
        #expect(!feed.isLoadingFirstTime)
        #expect(feed.loadError == nil)
        #expect(feed.isShown(HomeRows.continueWatching.id))
        #expect(feed.isShown(HomeRows.recentMovies.id))
        #expect(!feed.isShown(HomeRows.genre("Drama", type: "Movie").id))

        // Sam's Home on this device shows none of Alex's.
        let samsFeed = HomeFeed(defaults: defaults, cacheDirectory: directory)
        await samsFeed.load(session: Offline.session(Offline.sam, token: "sam"), isServerOutOfReach: true)
        #expect(samsFeed.rows.isEmpty)
        #expect(samsFeed.featured.isEmpty)
        #expect(samsFeed.items.isEmpty)
    }

    @Test func rowsRoundTripThroughTheirSavedForm() throws {
        let rows = [HomeRows.continueWatching, HomeRows.favorites, HomeRows.moreLike(Offline.item("m1", "Amber Cartographers")),
                    HomeRows.genre("Drama", type: "Series")]
        let decoded = try JSONDecoder().decode([HomeRow].self, from: JSONEncoder().encode(rows))
        #expect(decoded == rows)
    }
}

#if !os(tvOS)
struct OfflineDownloadsTests {
    private static let movie = Offline.item("m1", "Amber Cartographers")
    private static let episode = Offline.item("e2", "Dead Reckoning", type: "Episode", series: "Starfall Station")
    private static let other = Offline.item("e9", "Harbour Lights", type: "Episode", series: "Port Ellery")
    private static let video = Offline.item("v1", "Summer at the Lake", type: "Video")

    private static func finished(_ item: JellyfinItem, owner: AccountStore.Account? = Offline.alex,
                                 at date: Date = .now) -> DownloadJob {
        var job = DownloadJob(item: item, source: MediaSource(id: item.id + "-source", name: "1080p"), now: date)
        job.status = .completed
        job.owner = owner
        return job
    }

    @Test func findsDownloadsByTitleByShowAndByFileName() {
        let titles = [Self.movie, Self.episode, Self.other, Self.video]
        #expect(OfflineDownloads.search("amber", in: titles).movies == [Self.movie])
        // An episode by its show's name, and by its own.
        #expect(OfflineDownloads.search("starfall", in: titles).episodes == [Self.episode])
        #expect(OfflineDownloads.search("reckoning", in: titles).episodes == [Self.episode])
        #expect(OfflineDownloads.search("lake", in: titles).videos == [Self.video])
        // By the name of its file.
        let byFile = OfflineDownloads.search("pe02", in: titles, fileNames: [Self.other.id: "Port Ellery - S01E09 - pe02 Harbour Lights"])
        #expect(byFile.episodes == [Self.other])
        // Ignoring case and accents, and finding nothing for what's not there.
        #expect(OfflineDownloads.search("STARFÁLL", in: titles).episodes == [Self.episode])
        #expect(OfflineDownloads.search("copperline", in: titles).isEmpty)
    }

    @Test func theClosestMatchesComeFirst() {
        let close = Offline.item("m3", "Port")
        let loose = Offline.item("m4", "Airport Nights")
        #expect(OfflineDownloads.search("port", in: [loose, close]).movies == [close, loose])
    }

    @Test func offersOnlyTheSignInsFinishedDownloadsOnceEach() {
        var unfinished = Self.finished(Self.video)
        unfinished.status = .active
        // Another version of the same movie.
        let secondVersion = Self.finished(Self.movie)
        let jobs = [Self.finished(Self.movie), secondVersion, Self.finished(Self.episode, owner: Offline.sam),
                    Self.finished(Self.other, owner: nil), unfinished]
        let titles = OfflineDownloads.titles(jobs, of: Offline.alex) { _ in nil }
        // Sam's download pauses under Alex, and isn't Alex's to see; one saved before downloads
        // had a sign-in is everyone's.
        #expect(Set(titles.map(\.id)) == [Self.movie.id, Self.other.id])
        #expect(titles.count == 2)
    }

    @Test func leadsWithWhatsBeingWatchedAndEndsWithWhatsWatched() {
        let now = Date.now
        let watched = Self.finished(Self.other, at: now.addingTimeInterval(-60))
        let newest = Self.finished(Self.video, at: now.addingTimeInterval(-30))
        let started = Self.finished(Self.episode, at: now.addingTimeInterval(-3600))
        let older = Self.finished(Self.movie, at: now.addingTimeInterval(-7200))
        let history: [String: WatchHistory.Entry] = [
            Self.other.id: WatchHistory.Entry(position: 0, duration: 100, played: true, updatedAt: now, needsSync: false),
            Self.episode.id: WatchHistory.Entry(position: 40, duration: 100, played: false, updatedAt: now.addingTimeInterval(-10),
                                                needsSync: true),
        ]
        let titles = OfflineDownloads.titles([watched, newest, started, older], of: Offline.alex) { history[$0] }
        #expect(titles.map(\.id) == [Self.episode.id, Self.video.id, Self.movie.id, Self.other.id])
    }
}
#endif

struct PlayAvailabilityTests {
    private static let movie = Offline.item("m1", "Amber Cartographers")
    private static let show = Offline.item("s1", "Starfall Station", type: "Series")

    @Test func everythingPlaysWhileTheServerAnswers() {
        #expect(PlayAvailability.canPlay(Self.movie, isServerOutOfReach: false) { _, _ in false })
        #expect(PlayAvailability.canPlay(Self.show, isServerOutOfReach: false) { _, _ in false })
    }

    @Test func offlineOnlyWhatsDownloadedPlays() {
        #expect(PlayAvailability.canPlay(Self.movie, isServerOutOfReach: true) { id, _ in id == "m1" })
        #expect(!PlayAvailability.canPlay(Self.movie, isServerOutOfReach: true) { _, _ in false })
    }

    @Test func offlineTheVersionPickedHasToBeTheOneDownloaded() {
        let downloaded = { (id: String, source: String?) in id == "m1" && (source == nil || source == "4k") }
        #expect(PlayAvailability.canPlay(Self.movie, mediaSourceId: "4k", isServerOutOfReach: true, isDownloaded: downloaded))
        #expect(!PlayAvailability.canPlay(Self.movie, mediaSourceId: "1080p", isServerOutOfReach: true, isDownloaded: downloaded))
        // Without one picked, any version downloaded plays.
        #expect(PlayAvailability.canPlay(Self.movie, isServerOutOfReach: true, isDownloaded: downloaded))
    }

    @Test func offlineAShowDoesntPlayAsTheServerPicksItsEpisode() {
        #expect(!PlayAvailability.canPlay(Self.show, isServerOutOfReach: true) { _, _ in true })
    }
}

/// `playableOffline(_:)` on a control, as it's drawn.
@MainActor
struct PlayableOfflineTests {
    /// Whether the control was on as it was last drawn.
    private final class Seen {
        var isEnabled: Bool?
    }

    private struct Control: View {
        let seen: Seen
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            seen.isEnabled = isEnabled
            return Color.clear.frame(width: 10, height: 10)
        }
    }

    /// Runs `body` with the server answering or not, as the app would know.
    private func with<Result>(serverAnswers: Bool, _ body: (ServerReachability) -> Result) async -> Result {
        let reachability = ServerReachability(networkChanges: { AsyncStream { _ in } }) { _, _ in
            if !serverAnswers { throw URLError(.cannotConnectToHost) }
        }
        let following = Task { await reachability.follow(Offline.session(Offline.alex, token: "a")) }
        defer { following.cancel() }
        _ = await Offline.until { reachability.state != .unknown }
        return body(reachability)
    }

    /// Whether a control that plays `item` is on, with the server answering or not, and the item
    /// downloaded or not.
    private func isOn(_ item: JellyfinItem, serverAnswers: Bool, downloaded: Bool) async -> Bool? {
        await with(serverAnswers: serverAnswers) { reachability in
            let seen = Seen()
            let control = Control(seen: seen)
                .modifier(OfflinePlayability(item: item, mediaSourceId: nil, dims: true) { _, _ in downloaded })
                .environment(reachability)
            _ = ImageRenderer(content: control).cgImage
            return seen.isEnabled
        }
    }

    /// Whether a control whose change only the server can make is on, with the server answering
    /// or not.
    private func isOnNeedingServer(serverAnswers: Bool) async -> Bool? {
        await with(serverAnswers: serverAnswers) { reachability in
            let seen = Seen()
            let control = Control(seen: seen)
                .needsServer()
                .environment(reachability)
            _ = ImageRenderer(content: control).cgImage
            return seen.isEnabled
        }
    }

    /// Whether the title page's note under its actions draws at all.
    private func showsNote(serverAnswers: Bool, downloaded: Bool) async -> Bool {
        await with(serverAnswers: serverAnswers) { reachability in
            let note = OfflinePlayNote(item: Offline.item("m1", "Amber Cartographers"), mediaSourceId: nil) { _, _ in downloaded }
                .environment(reachability)
            return (ImageRenderer(content: note).cgImage?.width ?? 0) > 0
        }
    }

    @Test func suggestsDownloadingOnlyWhatDownloads() {
        let movie = Offline.item("m1", "Amber Cartographers")
        var trailer = Offline.item("t1", "Teaser", type: "Trailer")
        trailer.extraType = "Trailer"
        #if os(tvOS)
        #expect(OfflinePlayability.reason(for: movie, server: "Home") == "Can't reach Home.")
        #else
        #expect(OfflinePlayability.reason(for: movie, server: "Home") == "Can't reach Home. Download it to watch it offline.")
        #endif
        #expect(OfflinePlayability.reason(for: Offline.item("s1", "Starfall Station", type: "Series"), server: "Home") == "Can't reach Home.")
        #expect(OfflinePlayability.reason(for: trailer, server: "Home") == "Can't reach Home.")
    }

    @Test func theTitlePageSaysWhenWhatIsntDownloadedPlays() async {
        #expect(await showsNote(serverAnswers: false, downloaded: false))
        #expect(await !showsNote(serverAnswers: false, downloaded: true))
        #expect(await !showsNote(serverAnswers: true, downloaded: false))
    }

    @Test func playsWhileTheServerAnswers() async {
        #expect(await isOn(Offline.item("m1", "Amber Cartographers"), serverAnswers: true, downloaded: false) == true)
    }

    @Test func isOffForWhatIsntDownloadedWhileTheServerIsOutOfReach() async {
        #expect(await isOn(Offline.item("m1", "Amber Cartographers"), serverAnswers: false, downloaded: false) == false)
    }

    @Test func playsWhatsDownloadedWhileTheServerIsOutOfReach() async {
        #expect(await isOn(Offline.item("m1", "Amber Cartographers"), serverAnswers: false, downloaded: true) == true)
    }

    /// Marking watched, favourites and Remove from Continue Watching change what the server keeps.
    @Test func whatOnlyTheServerCanDoIsOffWhileItsOutOfReach() async {
        #expect(await isOnNeedingServer(serverAnswers: true) == true)
        #expect(await isOnNeedingServer(serverAnswers: false) == false)
    }

    /// A show's Shuffle and its menu's Play ask the server for the episodes; its page's Play plays
    /// the episode next, which may be downloaded.
    @Test func aShowsControlsWaitForTheServerButForADownloadedEpisode() async {
        let show = Offline.item("s1", "Starfall Station", type: "Series")
        let next = Offline.item("e2", "Episode 2", type: "Episode", series: "Starfall Station")
        #expect(await isOn(show, serverAnswers: false, downloaded: true) == false)
        #expect(await isOn(next, serverAnswers: false, downloaded: true) == true)
        #expect(await isOn(next, serverAnswers: false, downloaded: false) == false)
    }
}

/// The offline banner's words: "Offline" on its own line, so the rest never cuts it short.
@MainActor
struct OfflineBannerWordsTests {
    @Test func saysWhatShowsAndWhyUnderOffline() {
        let words = OfflineBanner.Words(showsDownloads: true, absence: .noAnswer, server: "Showcase")
        #expect(words.title == "Offline")
        #expect(words.detail == "Showing your downloads · Can't reach Showcase.")
        #expect(words.shortDetail == "Showing your downloads")
        #expect(words.spoken == "Offline: showing your downloads. Can't reach Showcase.")
    }

    @Test func withoutDownloadsSaysWhy() {
        let words = OfflineBanner.Words(showsDownloads: false, absence: .noAnswer, server: "The Family Media Server")
        #expect(words.detail == "Can't reach The Family Media Server.")
        #expect(words.shortDetail == "Can't reach the server.")
        #expect(words.spoken == "Offline. Can't reach The Family Media Server.")
    }

    @Test func saysWhenTheDeviceItselfIsOffline() {
        let words = OfflineBanner.Words(showsDownloads: true, absence: .deviceOffline, server: "Showcase")
        #expect(words.detail.hasPrefix("Showing your downloads · This "))
        #expect(words.detail.hasSuffix(" isn't connected to the internet."))
        #expect(OfflineBanner.Words(showsDownloads: false, absence: .deviceOffline, server: "Showcase").shortDetail
                == "No internet connection.")
    }
}

/// Images from a server out of reach: what the caches have shows, and the rest fail at once
/// rather than wait out the network's timeout, so a title's name stands in for its logo.
nonisolated struct OfflineImagesTests {
    private static let server = URL(string: "http://nas.local:8096")!
    private static let logo = URL(string: "http://nas.local:8096/Items/m1/Images/Logo?maxWidth=900&quality=90&tag=a")!
    private static let poster = URL(string: "http://nas.local:8096/Items/m1/Images/Primary?maxWidth=400&quality=90&tag=b")!
    private static let elsewhere = URL(string: "https://images.example.com/m1.png")!

    /// A red square, as PNG.
    private static let picture: Data = {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    /// A network that sends the picture for each load, or one that never answers, as a server
    /// out of reach doesn't, until the load is cancelled.
    private nonisolated final class FakeNetwork: DataLoading {
        private struct Cancel: Cancellable {
            let action: @Sendable () -> Void
            func cancel() { action() }
        }

        private let answers: Bool
        private let state = Mutex<(asked: [URL], waiting: [UUID: @Sendable ((any Error)?) -> Void])>(([], [:]))

        init(answers: Bool) {
            self.answers = answers
        }

        var asked: [URL] { state.withLock { $0.asked } }

        func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                      completion: @escaping @Sendable ((any Error)?) -> Void) -> any Cancellable {
            let url = request.url!
            state.withLock { $0.asked.append(url) }
            if answers {
                didReceiveData(OfflineImagesTests.picture, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                completion(nil)
                return Cancel {}
            }
            let id = UUID()
            state.withLock { $0.waiting[id] = completion }
            // As URLSession does, a cancelled load ends with an error.
            return Cancel { [self] in
                state.withLock { $0.waiting.removeValue(forKey: id) }?(URLError(.cancelled))
            }
        }
    }

    /// The pictures on disk, by key.
    private nonisolated final class FakeDisk: DataCaching {
        private let stored = Mutex<[String: Data]>([:])
        func cachedData(for key: String) -> Data? { stored.withLock { $0[key] } }
        func containsData(for key: String) -> Bool { cachedData(for: key) != nil }
        func storeData(_ data: Data, for key: String) { stored.withLock { $0[key] = data } }
        func removeData(for key: String) { stored.withLock { _ = $0.removeValue(forKey: key) } }
        func removeAll() { stored.withLock { $0.removeAll() } }
    }

    /// The errors loads ended with, by address.
    private nonisolated final class Endings: Sendable {
        private let errors = Mutex<[URL: any Error]>([:])
        func end(_ url: URL, _ error: (any Error)?) { errors.withLock { $0[url] = error } }
        subscript(url: URL) -> (any Error)? { errors.withLock { $0[url] } }
    }

    /// The error a load from `loader` ended with; nil when it loaded.
    private static func ending(of url: URL, from loader: ServerImageLoader) async -> (any Error)? {
        await withCheckedContinuation { continuation in
            _ = loader.loadData(with: URLRequest(url: url), didReceiveData: { _, _ in }) { error in
                continuation.resume(returning: error)
            }
        }
    }

    @Test func asksNothingOfAServerOutOfReach() async {
        let network = FakeNetwork(answers: true)
        let loader = ServerImageLoader(base: network)
        loader.serverOutOfReach(Self.server)
        #expect(await Self.ending(of: Self.logo, from: loader) is ImageServerOutOfReach)
        #expect(network.asked.isEmpty)
        // Pictures from elsewhere still load.
        #expect(await Self.ending(of: Self.elsewhere, from: loader) == nil)
        #expect(network.asked == [Self.elsewhere])
    }

    @Test func asksTheServerAgainOnceItAnswers() async {
        let network = FakeNetwork(answers: true)
        let loader = ServerImageLoader(base: network)
        loader.serverOutOfReach(Self.server)
        loader.serverOutOfReach(nil)
        #expect(await Self.ending(of: Self.logo, from: loader) == nil)
        #expect(network.asked == [Self.logo])
    }

    @Test func cutsShortWhatsLoadingFromTheServerAsItGoesOutOfReach() {
        let network = FakeNetwork(answers: false)
        let loader = ServerImageLoader(base: network)
        let endings = Endings()
        for url in [Self.logo, Self.elsewhere] {
            _ = loader.loadData(with: URLRequest(url: url), didReceiveData: { _, _ in }) { endings.end(url, $0) }
        }
        #expect(network.asked.count == 2)
        loader.serverOutOfReach(Self.server)
        #expect(endings[Self.logo] is ImageServerOutOfReach)
        // What's loading from elsewhere is left to finish.
        #expect(endings[Self.elsewhere] == nil)
    }

    @Test func knowsWhatsOnTheServer() {
        #expect(ServerImageLoader.isOn(Self.server, Self.logo))
        #expect(!ServerImageLoader.isOn(Self.server, URL(string: "http://nas.local:8920/Items/m1/Images/Logo")!))
        #expect(!ServerImageLoader.isOn(Self.server, URL(string: "https://nas.local:8096/Items/m1/Images/Logo")!))
        #expect(!ServerImageLoader.isOn(Self.server, URL(string: "http://other.local:8096/Items/m1/Images/Logo")!))
        // A server behind a proxy, under a path of its own.
        let proxied = URL(string: "https://example.com/jellyfin")!
        #expect(ServerImageLoader.isOn(proxied, URL(string: "https://example.com/jellyfin/Items/m1/Images/Logo")!))
        #expect(ServerImageLoader.isOn(URL(string: "https://example.com/jellyfin/")!, URL(string: "https://example.com/jellyfin/Items/m1")!))
        #expect(!ServerImageLoader.isOn(proxied, URL(string: "https://example.com/jellyfinx/Items/m1")!))
        #expect(!ServerImageLoader.isOn(proxied, URL(string: "https://example.com/Items/m1")!))
    }

    @Test func showsWhatsCachedAndFailsTheRestAtOnceWhileTheServerIsOutOfReach() async throws {
        let network = FakeNetwork(answers: false)
        let loader = ServerImageLoader(base: network)
        var configuration = ImagePipeline.Configuration()
        configuration.dataLoader = loader
        configuration.dataCache = FakeDisk()
        configuration.imageCache = nil
        let pipeline = ImagePipeline(configuration: configuration)
        pipeline.cache.storeCachedData(Self.picture, for: ImageRequest(url: Self.logo))
        loader.serverOutOfReach(Self.server)

        let cached = try await pipeline.image(for: Self.logo)
        #expect(cached.size.width > 0)
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await pipeline.image(for: Self.poster)
            Issue.record("Loaded a poster that isn't cached from a server out of reach")
        } catch {
            #expect(clock.now - started < .seconds(1))
            // Loaded again as the server answers, not on a timer meanwhile.
            #expect(Artwork.waitsForServer(error))
            #expect(!Artwork.isWorthRetrying(error))
        }
        #expect(network.asked.isEmpty)
    }

    @Test func onlyAFailureForTheServerBeingOutOfReachWaitsForIt() {
        #expect(Artwork.waitsForServer(ImagePipeline.Error.dataLoadingFailed(error: ImageServerOutOfReach())))
        #expect(!Artwork.waitsForServer(ImagePipeline.Error.dataLoadingFailed(error: URLError(.timedOut))))
        #expect(!Artwork.waitsForServer(ImagePipeline.Error.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(404))))
        #expect(!Artwork.waitsForServer(ImagePipeline.Error.cancelled))
    }
}
