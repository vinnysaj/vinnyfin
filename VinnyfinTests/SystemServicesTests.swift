import AppIntents
import Foundation
import GroupActivities
import Testing
@testable import vinnyfin
#if !os(tvOS)
import UserNotifications
#endif

/// Two people on one server and one of them on another, as the system's surfaces meet them.
private enum People {
    static let alex = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "home", serverName: "Home",
                                           userId: "u1", userName: "Alex")
    static let sam = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "home", serverName: "Home",
                                          userId: "u2", userName: "Sam")
    static let alexAtWork = AccountStore.Account(serverURL: URL(string: "https://jf.example.com")!, serverId: "work", serverName: "Work",
                                                 userId: "u1", userName: "Alex")

    static func session(_ account: AccountStore.Account) -> ServerSession {
        ServerSession(client: JellyfinClient(serverURL: account.serverURL, deviceId: "device", deviceName: "Test", token: "token"),
                      account: account)
    }

    /// The sign-ins kept in fresh defaults, with `inUse` in use, and their tokens.
    @MainActor
    static func accounts(inUse: AccountStore.Account?, kept: [AccountStore.Account]) throws -> AccountStore {
        let defaults = try #require(UserDefaults(suiteName: "SystemServicesTests-\(UUID().uuidString)"))
        if let inUse { defaults.set(try JSONEncoder().encode(inUse), forKey: "account") }
        defaults.set(try JSONEncoder().encode(kept), forKey: "accounts")
        let tokens = LockedTokens(Dictionary(uniqueKeysWithValues: kept.map { ($0.tokenKey, "token-\($0.userName)") }))
        return AccountStore(defaults: defaults, tokens: tokens.store) { _ in }
    }
}

private nonisolated final class LockedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String]

    init(_ tokens: [String: String]) {
        self.tokens = tokens
    }

    var store: AccountStore.TokenStore {
        AccountStore.TokenStore(read: { key in self.lock.withLock { self.tokens[key] } },
                                write: { token, key in self.lock.withLock { self.tokens[key] = token } },
                                delete: { key in self.lock.withLock { self.tokens[key] = nil } })
    }
}

// MARK: Which sign-in a title opens under

struct SignInChoiceTests {
    private let alexsTitle = AppLink.Owner(People.alex)

    @Test func opensAtOnceUnderTheSignInInUse() {
        #expect(SignInChoice.choose(for: alexsTitle, inUse: People.alex, kept: [People.alex, People.sam]) == .inUse)
    }

    /// A kept sign-in is switched to, with no password, rather than anyone being signed out.
    @Test func switchesToAKeptSignIn() {
        #expect(SignInChoice.choose(for: alexsTitle, inUse: People.sam, kept: [People.alex, People.sam]) == .switchTo(People.alex))
        #expect(SignInChoice.choose(for: alexsTitle, inUse: nil, kept: [People.alex]) == .switchTo(People.alex))
        #expect(SignInChoice.choose(for: alexsTitle, inUse: People.alexAtWork, kept: [People.alexAtWork, People.alex])
            == .switchTo(People.alex))
    }

    /// The same person's name on another server is someone else there.
    @Test func addsASignInThatIsntKept() {
        #expect(SignInChoice.choose(for: alexsTitle, inUse: People.sam, kept: [People.sam]) == .add)
        #expect(SignInChoice.choose(for: alexsTitle, inUse: People.alexAtWork, kept: [People.alexAtWork]) == .add)
        #expect(SignInChoice.choose(for: alexsTitle, inUse: nil, kept: []) == .add)
    }

    @Test func aHandedOffTitleNamesItsOwner() {
        let handoff = Handoff(link: AppLink(.play, Samples.movie, position: 60), signIn: ServerSignIn(People.alex))
        #expect(handoff.owner == alexsTitle)
        #expect(SignInChoice.choose(for: handoff.owner, inUse: People.sam, kept: [People.sam, People.alex]) == .switchTo(People.alex))
        #expect(SignInChoice.choose(for: handoff.owner, inUse: People.sam, kept: [People.sam]) == .add)
        #expect(SignInChoice.choose(for: handoff.owner, inUse: People.alex, kept: [People.alex]) == .inUse)
    }
}

// MARK: Links that say whose title they are

struct AccountLinkTests {
    @Test func carriesTheServerAndUserBothWays() throws {
        let link = AppLink(.play, Samples.movie, position: 90, for: People.sam)
        #expect(link.url.absoluteString == "vinnyfin://play/m1?type=Movie&name=Big%20Test%20Movie&position=90&server=home&user=u2")
        let read = try #require(AppLink(link.url))
        #expect(read == link)
        #expect(read.owner == AppLink.Owner(serverId: "home", userId: "u2"))
        #expect(read.owner?.isSignedIn(as: People.sam) == true)
        #expect(read.owner?.isSignedIn(as: People.alex) == false)
    }

    /// A link from before links named their sign-in, or naming only half of it, opens under the
    /// sign-in in use, as links did.
    @Test func aLinkWithoutBothOpensUnderTheSignInInUse() throws {
        #expect(AppLink(.open, Samples.movie).url.absoluteString == "vinnyfin://item/m1?type=Movie&name=Big%20Test%20Movie")
        #expect(try #require(AppLink(URL(string: "vinnyfin://item/m1?type=Movie&name=x")!)).owner == nil)
        #expect(try #require(AppLink(URL(string: "vinnyfin://item/m1?type=Movie&name=x&server=home")!)).owner == nil)
        #expect(try #require(AppLink(URL(string: "vinnyfin://item/m1?type=Movie&name=x&server=&user=u1")!)).owner == nil)
    }

    #if os(iOS) || os(macOS)
    @Test func widgetTilesLinkUnderTheirSignIn() throws {
        let owner = AppLink.Owner(People.alex)
        let tiles = UpNextWidgets.tiles(from: [Samples.movie], limit: 1, for: .favorites, owner: owner)
        let link = try #require(AppLink(tiles[0].link))
        #expect(link.owner == owner)
        #expect(link.action == .open)
    }
    #endif

    #if !os(tvOS)
    @Test func downloadsLinkUnderTheSignInThatDownloadedThem() throws {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.owner = People.sam
        let title = DownloadsSnapshot.Title(job)
        #expect(try #require(AppLink(title.playLink)).owner == AppLink.Owner(People.sam))
        #expect(try #require(AppLink(title.openLink)).owner == AppLink.Owner(People.sam))
        // A snapshot from before titles named their sign-in still reads.
        let old = Data(#"{"itemId":"m1","type":"Movie","name":"x","title":"x","hasArtwork":false}"#.utf8)
        #expect(try JSONDecoder().decode(DownloadsSnapshot.Title.self, from: old).owner == nil)
    }
    #endif
}

// MARK: Spotlight

#if !os(tvOS)
struct SpotlightSignInTests {
    private func download(_ item: JellyfinItem, by owner: AccountStore.Account?) -> DownloadJob {
        var job = DownloadJob(item: item, source: Samples.source)
        job.owner = owner
        return job
    }

    /// Two people on one server: neither's Spotlight gets the titles the other downloaded.
    @Test func putsOnlyTheSignInsOwnDownloadsIn() {
        let episode = Samples.item(#"{"Id":"e9","Name":"Pilot","Type":"Episode","SeriesId":"s9","SeriesName":"Port Ellery"}"#)
        let jobs = [download(Samples.movie, by: People.alex), download(episode, by: People.sam)]
        let alexs = SpotlightPlan.downloads(jobs, of: People.alex)
        #expect(alexs.itemIds == ["m1"])
        #expect(alexs.showIds.isEmpty)
        let sams = SpotlightPlan.downloads(jobs, of: People.sam)
        #expect(sams.itemIds == ["e9"])
        #expect(sams.showIds == ["s9"])
        // A download saved before downloads had a sign-in is the one in use's, as it is everywhere.
        #expect(SpotlightPlan.downloads([download(Samples.movie, by: nil)], of: People.sam).itemIds == ["m1"])
    }
}
#endif

// MARK: Reloading on a switch

@MainActor
struct SignInSurfacesTests {
    /// Widgets, Top Shelf, Siri's titles and what Siri learned follow each change of sign-in, and
    /// not the sign-in the app opens with.
    @Test func refreshesOnEachChangeOfSignIn() async throws {
        let accounts = try People.accounts(inUse: People.alex, kept: [People.alex, People.sam])
        let refreshes = Refreshes()
        let following = Task { await SignInSurfaces.follow(accounts) { refreshes.count += 1 } }
        defer { following.cancel() }
        // The sign-in in use at the start has been seen, and isn't a change.
        try await Task.sleep(for: .milliseconds(300))
        #expect(refreshes.count == 0)

        try accounts.switchTo(People.sam)
        try await refreshes.reach(1)
        try accounts.switchTo(People.alex)
        try await refreshes.reach(2)
        // Signed out, the widgets say so rather than keeping the last person's titles.
        accounts.signOut()
        try await refreshes.reach(3)
    }

    @Test func doesNothingUntilTheSignInChanges() async throws {
        let accounts = try People.accounts(inUse: People.alex, kept: [People.alex])
        let refreshes = Refreshes()
        let following = Task { await SignInSurfaces.follow(accounts) { refreshes.count += 1 } }
        try await Task.sleep(for: .milliseconds(300))
        following.cancel()
        #expect(refreshes.count == 0)
    }
}

@MainActor
private final class Refreshes {
    var count = 0

    /// Waits up to a few seconds for `count` refreshes.
    func reach(_ expected: Int) async throws {
        for _ in 0..<100 where count < expected {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(count == expected)
    }
}

// MARK: Siri and Spotlight offline

#if !os(tvOS)
struct OfflineEntityTests {
    private let episode = Samples.item("""
    {"Id":"e3","Name":"The Lighthouse","Type":"Episode","SeriesId":"s1","SeriesName":"Port Ellery","SeriesPrimaryImageTag":"sp","ParentIndexNumber":1,"IndexNumber":3}
    """)

    private func download(_ item: JellyfinItem, by owner: AccountStore.Account?) -> DownloadJob {
        var job = DownloadJob(item: item, source: Samples.source)
        job.owner = owner
        return job
    }

    @Test func findsWhatTheSignInDownloadedAsItSavedIt() {
        let jobs = [download(Samples.movie, by: People.alex), download(episode, by: People.alex)]
        let movies = OfflineTitles.items(ids: ["m1", "missing"], type: "Movie", in: jobs, of: People.alex)
        #expect(movies.map(\.id) == ["m1"])
        #expect(movies.first?.name == "Big Test Movie")
        #expect(OfflineTitles.items(ids: ["e3"], type: "Episode", in: jobs, of: People.alex).first?.seriesName == "Port Ellery")
        // A movie's id isn't an episode's.
        #expect(OfflineTitles.items(ids: ["m1"], type: "Episode", in: jobs, of: People.alex).isEmpty)
    }

    @Test func findsAShowByItsDownloadedEpisodes() throws {
        let shows = OfflineTitles.items(ids: ["s1"], type: "Series", in: [download(episode, by: People.alex)], of: People.alex)
        let show = try #require(shows.first)
        #expect(show.id == "s1")
        #expect(show.name == "Port Ellery")
        #expect(show.type == "Series")
        #expect(show.primaryImageTag == "sp")
    }

    @Test func neverFindsAnotherSignInsDownloads() {
        let jobs = [download(Samples.movie, by: People.sam), download(episode, by: People.alexAtWork)]
        #expect(OfflineTitles.items(ids: ["m1"], type: "Movie", in: jobs, of: People.alex).isEmpty)
        #expect(OfflineTitles.items(ids: ["s1"], type: "Series", in: jobs, of: People.alex).isEmpty)
        #expect(OfflineTitles.items(ids: ["m1"], type: "Movie", in: jobs, of: People.sam).map(\.id) == ["m1"])
    }

    /// Only a server out of reach falls back; one that answered, even with an error, is believed.
    @Test func fallsBackOnlyWhenTheServerCantBeReached() {
        #expect(ServerTitles.isUnreachable(URLError(.notConnectedToInternet)))
        #expect(ServerTitles.isUnreachable(URLError(.cannotConnectToHost)))
        #expect(ServerTitles.isUnreachable(URLError(.timedOut)))
        #expect(!ServerTitles.isUnreachable(URLError(.cancelled)))
        #expect(!ServerTitles.isUnreachable(JellyfinError.http(status: 404, body: "")))
        #expect(!ServerTitles.isUnreachable(CancellationError()))
    }
}
#endif

// MARK: What Siri learns

struct DonationTests {
    private let session = People.session(People.alex)

    @Test func aMovieTeachesSiriToPlayIt() throws {
        let intent = try #require(PlaybackDonation.intent(for: Samples.movie, session: session) as? PlayMovieIntent)
        #expect(intent.movie.id == "m1")
        #expect(intent.movie.name == "Big Test Movie")
    }

    @Test func anEpisodeTeachesSiriToContinueItsShow() throws {
        let episode = Samples.item("""
        {"Id":"e3","Name":"The Lighthouse","Type":"Episode","SeriesId":"s1","SeriesName":"Port Ellery","SeriesPrimaryImageTag":"sp"}
        """)
        let intent = try #require(PlaybackDonation.intent(for: episode, session: session) as? ContinueWatchingIntent)
        #expect(intent.show.id == "s1")
        #expect(intent.show.name == "Port Ellery")
        #expect(intent.show.poster == session.client.imageURL(itemId: "s1", tag: "sp", maxWidth: ServerTitles.posterWidth))
    }

    @Test func otherTitlesTeachItNothing() {
        #expect(PlaybackDonation.intent(for: JellyfinItem(id: "v1", name: "Clip", type: "Video"), session: session) == nil)
        // An episode without its show has no show to continue.
        #expect(PlaybackDonation.intent(for: JellyfinItem(id: "e1", name: "Pilot", type: "Episode"), session: session) == nil)
    }

    @Test func whatsDonatedIsWhatASwitchForgets() {
        let types = PlaybackDonation.types.map { String(describing: $0) }
        #expect(types.contains(String(describing: PlayMovieIntent.self)))
        #expect(types.contains(String(describing: ContinueWatchingIntent.self)))
    }

    @Test func theEntitiesGoElsewhereWithTheirWebPage() {
        let movie = MovieEntity(Samples.movie, session: session)
        #expect(movie.webpage?.absoluteString == "http://nas.local:8096/web/#/details?id=m1&serverId=home")
        let text = TitleSharing.text(of: Samples.movie, page: movie.webpage)
        #expect(text == "Big Test Movie (2024)\nMovie\nhttp://nas.local:8096/web/#/details?id=m1&serverId=home")
    }

    #if !os(tvOS)
    @Test func pausesOrResumesAsNothingSaidDoesSomething() {
        var active = DownloadJob(item: Samples.movie, source: Samples.source)
        var paused = active
        paused.status = .paused
        #expect(DownloadsAction.toggling([paused, active]) == .pause)
        active.status = .completed
        #expect(DownloadsAction.toggling([paused, active]) == .resume)
        #expect(DownloadsAction.toggling([]) == .resume)
    }
    #endif
}

// MARK: Notifications

#if !os(tvOS)
struct ReadyNotificationContentTests {
    private func episode(_ number: Int, by owner: AccountStore.Account? = nil) -> DownloadJob {
        let item = Samples.item("""
        {"Id":"ep\(number)","Name":"Episode \(number)","Type":"Episode","SeriesName":"Port Ellery","SeriesId":"s1","ParentIndexNumber":1,"IndexNumber":\(number)}
        """)
        var job = DownloadJob(item: item, source: Samples.source)
        job.owner = owner
        return job
    }

    @Test func showsTheTitleWithPlayAndOpen() throws {
        var movie = DownloadJob(item: Samples.movie, source: Samples.source)
        movie.owner = People.alex
        let poster = URL(filePath: "/tmp/m1-Primary.jpg")
        let notice = try #require(ReadyNotice.notices(for: [movie], delivered: [:], posters: ["m1": poster]).first)
        #expect(notice.poster == poster)
        let content = notice.content()
        #expect(content.title == "Big Test Movie (2024)")
        #expect(content.body == "Ready to watch offline.")
        #expect(content.categoryIdentifier == ReadyNotice.categoryIdentifier)
        #expect(content.threadIdentifier == notice.identifier)
        #expect(content.relevanceScore == ReadyNotice.relevance)
        #expect(content.relevanceScore > AttentionNotice.relevance)
        #expect(content.interruptionLevel == .active)
        #expect(content.sound != nil)
        let open = try #require((content.userInfo[ReadyNotice.linkKey] as? String).flatMap(URL.init(string:)).flatMap(AppLink.init))
        let play = try #require((content.userInfo[ReadyNotice.playLinkKey] as? String).flatMap(URL.init(string:)).flatMap(AppLink.init))
        #expect(open.action == .open)
        #expect(play.action == .play)
        #expect(play.itemId == "m1")
        // Both open under the sign-in that downloaded it.
        #expect(open.owner == AppLink.Owner(People.alex))
        #expect(play.owner == AppLink.Owner(People.alex))
        #expect(content.userInfo[ReadyNotice.itemsKey] as? [String] == ["m1"])
    }

    @Test func offersPlayAndOpen() {
        let category = ReadyNotice.category
        #expect(category.identifier == ReadyNotice.categoryIdentifier)
        #expect(category.actions.map(\.identifier) == [ReadyNotice.playAction, ReadyNotice.openAction])
        #expect(category.actions.allSatisfy { $0.options.contains(.foreground) })
    }

    /// A show's episodes open the show, and Play starts the earliest of them.
    @Test func playsAShowsEarliestEpisodeReady() throws {
        let notice = try #require(ReadyNotice.notices(for: [episode(4), episode(2), episode(3)], delivered: [:]).first)
        #expect(notice.title == "Port Ellery")
        #expect(AppLink(notice.link)?.itemId == "s1")
        #expect(AppLink(notice.playLink)?.itemId == "ep2")
        #expect(AppLink(notice.playLink)?.action == .play)
    }

    @Test func anUpdateComesInQuietly() throws {
        let first = try #require(ReadyNotice.notices(for: [episode(1)], delivered: [:]).first)
        let next = try #require(ReadyNotice.notices(for: [episode(2)], delivered: [first.identifier: first.itemIds]).first)
        let content = next.content()
        #expect(content.interruptionLevel == .passive)
        #expect(content.sound == nil)
    }

    /// Two people downloading one show each hear of their own episodes, and nobody else's.
    @Test func keepsEachSignInsEpisodesApart() {
        let notices = ReadyNotice.notices(for: [episode(1, by: People.alex), episode(2, by: People.sam)], delivered: [:])
        #expect(notices.count == 2)
        #expect(Set(notices.map(\.identifier)).count == 2)
        #expect(notices.allSatisfy { $0.itemIds.count == 1 })
        #expect(notices.map { AppLink($0.link)?.owner } == [AppLink.Owner(People.alex), AppLink.Owner(People.sam)])
    }

    @Test func whatNeedsAttentionOpensUnderItsSignIn() throws {
        var failed = DownloadJob(item: Samples.movie, source: Samples.source)
        failed.status = .failed
        failed.owner = People.sam
        let notice = AttentionNotice([.failed(failed.id)], jobs: [failed], waits: [:], serverName: "Home", hasStorageLimit: false)
        #expect(try #require(notice.link.flatMap(AppLink.init)).owner == AppLink.Owner(People.sam))
        let content = notice.content(thread: "attention")
        #expect(content.title == notice.title)
        #expect(content.relevanceScore == AttentionNotice.relevance)
        #expect(content.categoryIdentifier.isEmpty)
    }
}
#endif

// MARK: Widgets

#if os(iOS) || os(macOS)
struct WidgetFillTests {
    @Test func fillsContinueWatchingWithWhatsNew() {
        let partway = UpNextWidgets.tiles(from: [Samples.movie], limit: 2, owner: AppLink.Owner(People.alex))
        let newest = [Samples.movie, JellyfinItem(id: "s5", name: "Harbor Lights", type: "Series"), JellyfinItem(id: "m6", name: "Later", type: "Movie")]
        let tiles = UpNextWidgets.filling(partway, from: newest, limit: 2, server: "Home", owner: AppLink.Owner(People.alex))
        #expect(tiles.map(\.itemId) == ["m1", "s5"])
        #expect(tiles[0].plays)
        #expect(!tiles[1].plays)
        #expect(tiles[1].detail == "New on Home")
        #expect(AppLink(tiles[1].link)?.action == .open)
        #expect(AppLink(tiles[1].link)?.owner == AppLink.Owner(People.alex))
        #expect(UpNextWidgets.fills(.continueWatching))
        #expect(!UpNextWidgets.fills(.favorites))
        #expect(!UpNextWidgets.fills(.recentlyAdded))
    }

    @Test func fillsNothingWhenTheRowIsFull() {
        let full = UpNextWidgets.tiles(from: [Samples.movie], limit: 1)
        #expect(UpNextWidgets.filling(full, from: [JellyfinItem(id: "s5", name: "Harbor Lights", type: "Series")], limit: 1,
                                      server: "Home", owner: nil) == full)
    }
}
#endif

#if os(macOS)
/// The Dock menu's titles against a server where Alex and Sam are each partway through a movie of
/// their own (`DockTitlesStub`).
@MainActor
struct DockTitlesSignInTests {
    private static let address = URL(string: "https://\(DockTitlesStub.host)")!
    private let alex = AccountStore.Account(serverURL: Self.address, serverId: "dock", serverName: "Dock", userId: "alex", userName: "Alex")
    private let sam = AccountStore.Account(serverURL: Self.address, serverId: "dock", serverName: "Dock", userId: "sam", userName: "Sam")

    /// After a switch, none of the last person's titles are listed, even before the new
    /// sign-in's come; then the new sign-in's are. Signed out, none are.
    @Test func aSwitchEmptiesThenReplacesTheTitles() async throws {
        DockTitlesStub.register()
        let accounts = try People.accounts(inUse: alex, kept: [alex, sam])
        let titles = DockTitles(accounts: accounts)
        await titles.refresh()
        #expect(titles.listed.map(\.title) == ["Alex's Movie"])
        #expect(AppLink(titles.listed[0].link)?.owner == AppLink.Owner(alex))

        try accounts.switchTo(sam)
        #expect(titles.listed.isEmpty)
        await titles.refresh()
        #expect(titles.listed.map(\.title) == ["Sam's Movie"])

        accounts.signOut()
        #expect(titles.listed.isEmpty)
        await titles.refresh()
        try accounts.switchTo(alex)
        // Signing out let Sam's go, and Alex's come again only when asked for.
        #expect(titles.listed.isEmpty)
        await titles.refresh()
        #expect(titles.listed.map(\.title) == ["Alex's Movie"])
    }

    /// Titles asked for before a switch that come back after it don't replace the new sign-in's.
    @Test func dropsTitlesThatComeBackAfterASwitch() async throws {
        DockTitlesStub.register()
        let accounts = try People.accounts(inUse: alex, kept: [alex, sam])
        let titles = DockTitles(accounts: accounts)
        DockTitlesStub.answersSlowly(to: "alex")
        defer { DockTitlesStub.answersSlowly(to: nil) }
        let late = Task { await titles.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        try accounts.switchTo(sam)
        await titles.refresh()
        await late.value
        #expect(titles.listed.map(\.title) == ["Sam's Movie"])
    }
}

/// A server for `DockTitlesSignInTests`: each user is partway through a movie named for them, and
/// there's nothing else. One user's answers can be made to come late.
nonisolated final class DockTitlesStub: URLProtocol {
    static let host = "dock-titles.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var slowUser: String?
    private static let registered: Void = { URLProtocol.registerClass(DockTitlesStub.self) }()

    static func register() {
        _ = registered
    }

    static func answersSlowly(to userId: String?) {
        lock.withLock { slowUser = userId }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let userId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == "userid" }?.value
            ?? url.path().split(separator: "/").dropFirst().first.map(String.init) ?? ""
        let body: String
        if url.path().hasSuffix("UserItems/Resume") {
            let name = userId == "alex" ? "Alex's Movie" : "Sam's Movie"
            body = #"{"Items":[{"Id":"movie-\#(userId)","Name":"\#(name)","Type":"Movie","RunTimeTicks":60000000000,"UserData":{"PlaybackPositionTicks":6000000000,"PlayedPercentage":10}}],"TotalRecordCount":1}"#
        } else {
            body = #"{"Items":[],"TotalRecordCount":0}"#
        }
        if Self.lock.withLock({ Self.slowUser == userId }) { Thread.sleep(forTimeInterval: 0.6) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif

// MARK: Now Playing

struct NowPlayingChapterTests {
    /// Listed in the order the server gave them, which isn't always the order they play.
    private let chapters = ChapterMark.of(Samples.item("""
    {"Id":"m1","Name":"Big Test Movie","Type":"Movie","Chapters":[
     {"StartPositionTicks":6000000000,"Name":"The Storm"},
     {"StartPositionTicks":0,"Name":"Arrival"},
     {"StartPositionTicks":12000000000,"Name":"Morning"}]}
    """)) { _, _ in nil }

    @Test func numbersTheChapterPlayingFromZeroInTheOrderTheyPlay() {
        #expect(chapters.map(\.name) == ["Arrival", "The Storm", "Morning"])
        #expect(PlayerModel.nowPlayingChapterNumber(in: chapters, at: 0) == 0)
        #expect(PlayerModel.nowPlayingChapterNumber(in: chapters, at: 599) == 0)
        #expect(PlayerModel.nowPlayingChapterNumber(in: chapters, at: 600) == 1)
        #expect(PlayerModel.nowPlayingChapterNumber(in: chapters, at: 5000) == 2)
    }

    @Test func numbersNoChapterBeforeTheFirstOrWithoutChapters() {
        let late = Array(chapters.dropFirst())
        #expect(PlayerModel.nowPlayingChapterNumber(in: late, at: 10) == nil)
        #expect(PlayerModel.nowPlayingChapterNumber(in: late, at: 700) == 0)
        #expect(PlayerModel.nowPlayingChapterNumber(in: [], at: 10) == nil)
    }
}

// MARK: SharePlay

struct WatchTogetherSignInTests {
    private let activity = WatchTogether(serverId: "home", serverName: "Home", itemId: "m1", title: "Big Test Movie (2024)")

    @Test func findsTheSignInsKeptToTheGroupsServer() {
        #expect(activity.keptSignIns(among: [People.alexAtWork, People.sam, People.alex]) == [People.sam, People.alex])
        #expect(activity.keptSignIns(among: [People.alexAtWork]).isEmpty)
    }

    @Test func asksBeforeSwitching() {
        #expect(activity.switchQuestion(signedIn: People.alexAtWork, kept: [People.sam], isPlaying: false)
            == "Big Test Movie (2024) is playing from Home. vinnyfin here is using Work as Alex. Sam's sign-in to it is kept here, so switching needs no password. Alex stays signed in to switch back to.")
        #expect(activity.switchQuestion(signedIn: nil, kept: [People.sam, People.alex], isPlaying: true)
            == "Big Test Movie (2024) is playing from Home. vinnyfin here isn't signed in. Sign-ins to it are kept here, so switching needs no password. What's playing here stops.")
    }

    /// The poster stays on the device that starts the group: the activity the others get leaves it out.
    @Test func keepsThePreviewToItself() throws {
        var shown = activity
        shown.preview = Data([0xFF, 0xD8, 0xFF])
        let sent = try JSONDecoder().decode(WatchTogether.self, from: JSONEncoder().encode(shown))
        #expect(sent.preview == nil)
        #expect(sent.itemId == "m1")
        #expect(sent.serverId == "home")
    }
}
