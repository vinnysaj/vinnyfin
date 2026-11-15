import Foundation
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

    @Test func rowsRoundTripThroughTheirSavedForm() throws {
        let rows = [HomeRows.continueWatching, HomeRows.favorites, HomeRows.moreLike(Offline.item("m1", "Amber Cartographers")),
                    HomeRows.genre("Drama", type: "Series")]
        let decoded = try JSONDecoder().decode([HomeRow].self, from: JSONEncoder().encode(rows))
        #expect(decoded == rows)
    }
}
