import Foundation
import Observation
import OSLog

/// Who is signed in to which server. Several sign-ins can be kept on a device, each its own
/// server and user, and one is in use at a time; switching between them needs no password. Each
/// one's token lives in the `Keychain`, under its server's id and its user's (`Account.tokenKey`).
/// On Apple TV, iPhone, iPad and the Mac the sign-ins are kept in the app group, where the app's
/// extensions read the one in use to ask the server what's up next: Apple TV's Top Shelf, and
/// the Up Next widgets. Each person on a shared Apple TV has sign-ins of their own: the app and
/// Top Shelf run as the user picked in Control Center, and tvOS keeps each user's app group and
/// Keychain apart.
@Observable
final class AccountStore {
    nonisolated struct Account: Codable, Equatable, Sendable {
        var serverURL: URL
        var serverId: String
        var serverName: String?
        var userId: String
        var userName: String

        /// What to call the server in a sentence.
        var serverTitle: String { serverName ?? serverURL.host() ?? "the server" }

        /// Whether `other` is this person on this server, wherever the server is and whatever
        /// it's called now.
        func isSame(as other: Account?) -> Bool {
            other?.serverId == serverId && other?.userId == userId
        }

        /// The Keychain's name for the token: the server's id and the user's, so two people on
        /// one server each keep theirs.
        var tokenKey: String { Self.tokenKey(serverId: serverId, userId: userId) }

        static func tokenKey(serverId: String, userId: String) -> String {
            serverId + "/" + userId
        }
    }

    /// A Jellyfin server that answered at an address, before anyone signs in to it.
    nonisolated struct Server: Sendable {
        var url: URL
        var info: PublicSystemInfo

        /// What to call the server in a sentence.
        var title: String { info.serverName ?? url.host() ?? "the server" }
    }

    /// Where the tokens are, by `Account.tokenKey`.
    nonisolated struct TokenStore: Sendable {
        var read: @Sendable (_ key: String) throws -> String?
        var write: @Sendable (_ token: String, _ key: String) throws -> Void
        var delete: @Sendable (_ key: String) throws -> Void

        /// The app group's Keychain items, which the extensions read too.
        static let keychain = TokenStore(read: { try Keychain.token(for: $0) }, write: { try Keychain.setToken($0, for: $1) },
                                         delete: { try Keychain.deleteToken(for: $0) })
    }

    /// The sign-ins kept on this device, the one in use among them, in the order they were first
    /// made here.
    private(set) var saved: [Account] = []
    /// The sign-in in use.
    private(set) var account: Account?
    private(set) var client: JellyfinClient?
    /// Why the sign-in in use can't be used: its token isn't in the Keychain, or the Keychain
    /// wouldn't give it. Nil when there's none saved, or it's in use.
    private(set) var savedSignInProblem: String?
    #if os(iOS) || os(macOS)
    /// Why the sign-in couldn't be moved where the widgets read it. The app stays signed in.
    private(set) var sharingProblem: String?
    #endif

    /// Deletes what the app keeps on this device for a sign-in that's no longer kept here, such
    /// as Home's saved rows: signed out of, or gone from the Keychain.
    @ObservationIgnored var forgetting: (Account) -> Void = { _ in }

    private let defaults: UserDefaults
    private let tokens: TokenStore
    /// Tells the server a sign-in has ended.
    private let endSession: @Sendable (JellyfinClient) async throws -> Void
    /// The sign-in in use, which the extensions read.
    nonisolated private static let accountKey = "account"
    /// Every sign-in kept on this device.
    nonisolated private static let savedKey = "accounts"
    nonisolated private static let deviceIdKey = "deviceId"
    nonisolated private static let lastServerKey = "lastServer"
    nonisolated private static let lastServerNameKey = "lastServerName"
    nonisolated private static let lastUserNameKey = "lastUserName"
    /// How long telling the server about a sign-out may take, in the background, before it's
    /// given up on: a server out of reach keeps a token no one uses.
    static let signOutTimeLimit = Duration.seconds(15)
    nonisolated private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "accounts")

    /// Where the sign-ins are kept: on Apple TV, iPhone, iPad and the Mac the app group's
    /// defaults, shared with the app's extensions.
    nonisolated static var savedDefaults: UserDefaults {
        #if os(visionOS)
        .standard
        #else
        // A suite is refused only when it's named after the app itself.
        UserDefaults(suiteName: AppGroup.identifier)!
        #endif
    }

    /// The sign-ins saved in `defaults`, as an extension reads them.
    convenience init(defaults: UserDefaults = savedDefaults) {
        self.init(defaults: defaults, tokens: .keychain)
    }

    /// The sign-ins saved in `defaults`, with their tokens in `tokens`, telling the server of a
    /// sign-out with `endSession`.
    init(defaults: UserDefaults, tokens: TokenStore,
         endSession: @escaping @Sendable (JellyfinClient) async throws -> Void = { try await $0.signOut() }) {
        self.defaults = defaults
        self.tokens = tokens
        self.endSession = endSession
        do {
            let account = try Self.savedAccount(in: defaults)
            saved = try Self.savedAccounts(in: defaults) ?? account.map { [$0] } ?? []
            guard let account else { return }
            guard let token = try Self.token(of: account, in: tokens) else {
                savedSignInProblem = "The sign-in to \(account.serverTitle) isn't in the Keychain."
                return
            }
            self.account = account
            client = JellyfinClient(serverURL: account.serverURL, deviceId: deviceId, deviceName: Device.ownName, token: token)
        } catch {
            Self.log.error("Couldn't read the saved sign-in: \(error.localizedDescription, privacy: .public)")
            savedSignInProblem = error.localizedDescription
        }
    }

    #if os(iOS) || os(macOS)
    /// The app's sign-in, moved first from where only the app reads it to the app group, for the
    /// widgets. While it can't be moved, the app keeps it where it is for this run: in its own
    /// defaults, with its own Keychain item, or the group's for a sign-in saved since.
    convenience init(movingSignInFrom appDefaults: UserDefaults) {
        let moveError: (any Error)?
        do {
            try Self.moveSignInToAppGroup(from: appDefaults, to: Self.savedDefaults)
            moveError = nil
        } catch {
            moveError = error
        }
        guard let moveError else {
            self.init(defaults: Self.savedDefaults)
            return
        }
        Self.log.error("Couldn't move the sign-in to the app group: \(moveError.localizedDescription, privacy: .public)")
        var tokens = TokenStore.keychain
        tokens.read = { key in try Keychain.appToken(for: key) ?? Keychain.token(for: key) }
        self.init(defaults: appDefaults, tokens: tokens)
        sharingProblem = "The widgets can't use your sign-in: \(moveError.localizedDescription) vinnyfin stays signed in and tries again the next time it opens."
    }
    #endif

    nonisolated private static func savedAccount(in defaults: UserDefaults) throws -> Account? {
        guard let data = defaults.data(forKey: accountKey) else { return nil }
        return try JSONDecoder().decode(Account.self, from: data)
    }

    /// Nil when no list is saved, as when a device kept one sign-in, the one in use.
    nonisolated private static func savedAccounts(in defaults: UserDefaults) throws -> [Account]? {
        guard let data = defaults.data(forKey: savedKey) else { return nil }
        return try JSONDecoder().decode([Account].self, from: data)
    }

    /// The account's token: under its own name, or else under its server's id alone, where a
    /// device that kept one sign-in had it, and which it's moved from to its own name. A move
    /// that fails leaves it where it was, to move the next time.
    nonisolated static func token(of account: Account, in tokens: TokenStore) throws -> String? {
        if let token = try tokens.read(account.tokenKey) { return token }
        guard let token = try tokens.read(account.serverId) else { return nil }
        do {
            try tokens.write(token, account.tokenKey)
            try tokens.delete(account.serverId)
        } catch {
            log.error("Couldn't move the token of \(account.serverTitle, privacy: .public) to its own name: \(error.localizedDescription, privacy: .public)")
        }
        return token
    }

    /// The signed-in server and user, for browsing.
    var session: ServerSession? {
        guard let client, let account else { return nil }
        return ServerSession(client: client, account: account)
    }

    /// The sign-ins kept on this device other than the one in use, to switch to.
    var others: [Account] {
        saved.filter { !$0.isSame(as: account) }
    }

    /// Identifies this install to the server; Jellyfin lists sessions by it.
    var deviceId: String {
        if let id = defaults.string(forKey: Self.deviceIdKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.deviceIdKey)
        return id
    }

    /// The server and user of the last sign-in, which the sign-in screen starts from after signing
    /// out, and what the server's called when it has a name.
    var lastServerURL: URL? { defaults.url(forKey: Self.lastServerKey) }
    var lastServerName: String? { defaults.string(forKey: Self.lastServerNameKey) }
    var lastUserName: String? { defaults.string(forKey: Self.lastUserNameKey) }

    /// The Jellyfin server at the address, found without signing in.
    func findServer(at serverURL: URL) async throws -> Server {
        Server(url: serverURL, info: try await publicClient(for: serverURL).publicSystemInfo())
    }

    /// The people the server lists on its sign-in screen. Many servers list no one.
    func publicUsers(on serverURL: URL) async throws -> [PublicUser] {
        try await publicClient(for: serverURL).publicUsers()
    }

    /// A person's picture on the server, about `points` wide on screen; nil when they have none.
    func pictureURL(of user: PublicUser, on serverURL: URL, points: Int) -> URL? {
        guard let tag = user.primaryImageTag else { return nil }
        return publicClient(for: serverURL).userImageURL(userId: user.id, tag: tag, maxWidth: points * 3)
    }

    /// Signs in with the password, once `signedIn` has had its say: the server has given the
    /// sign-in by then, which only takes the app over after.
    func signIn(to server: Server, username: String, password: String,
                signedIn: @MainActor () async throws -> Void = {}) async throws {
        let client = publicClient(for: server.url)
        let result = try await client.authenticate(username: username, password: password)
        try await signedIn()
        try Task.checkCancellation()
        try adopt(result, on: server, client: client)
    }

    /// Starts a Quick Connect sign-in: the code is entered in an app that is already signed in.
    func startQuickConnect(on server: Server) async throws -> QuickConnectState {
        let client = publicClient(for: server.url)
        guard try await client.quickConnectEnabled() else { throw JellyfinError.quickConnectDisabled }
        return try await client.initiateQuickConnect()
    }

    /// Waits for the code to be approved, then signs in with it, once `signedIn` has had its say:
    /// the server has given the sign-in by then, which only takes the app over after. Ends when
    /// the calling task is cancelled.
    func finishQuickConnect(on server: Server, secret: String, signedIn: @MainActor () async throws -> Void) async throws {
        let client = publicClient(for: server.url)
        while try await !client.quickConnectState(secret: secret).authenticated {
            try await Task.sleep(for: .seconds(2))
        }
        let result = try await client.authenticate(quickConnectSecret: secret)
        try await signedIn()
        try Task.checkCancellation()
        try adopt(result, on: server, client: client)
    }

    /// A client of the server for its public calls and for signing in, with no one signed in yet.
    private func publicClient(for serverURL: URL) -> JellyfinClient {
        JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.ownName)
    }

    /// Keeps the sign-in the server gave, beside any others kept here, and uses it.
    private func adopt(_ result: AuthenticationResult, on server: Server, client: JellyfinClient) throws {
        var client = client
        client.token = result.accessToken
        let account = Account(
            serverURL: server.url,
            serverId: result.serverId,
            serverName: server.info.serverName,
            userId: result.user.id,
            userName: result.user.name
        )
        try tokens.write(result.accessToken, account.tokenKey)
        #if os(iOS) || os(macOS)
        // The next launch's move would take a token left where only the app read it for newer.
        try Keychain.deleteAppToken(for: account.serverId)
        #endif
        if let index = saved.firstIndex(where: { $0.isSame(as: account) }) {
            saved[index] = account
        } else {
            saved.append(account)
        }
        use(account, client: client)
    }

    /// Switches to a sign-in kept on this device, with the token kept for it. One whose token is
    /// gone can't be used any more: it's no longer kept, and this throws.
    func switchTo(_ account: Account) throws {
        guard let account = saved.first(where: { $0.isSame(as: account) }) else { throw AccountError.notKept(account) }
        guard let token = try Self.token(of: account, in: tokens) else {
            saved.removeAll { $0.isSame(as: account) }
            saveList()
            forgetting(account)
            throw AccountError.tokenMissing(account)
        }
        use(account, client: JellyfinClient(serverURL: account.serverURL, deviceId: deviceId, deviceName: Device.ownName, token: token))
    }

    /// Makes the sign-in the one in use, and the one the sign-in screen starts from after it ends.
    private func use(_ account: Account, client: JellyfinClient) {
        do {
            defaults.set(try JSONEncoder().encode(account), forKey: Self.accountKey)
        } catch {
            Self.log.error("Couldn't save the sign-in in use: \(error.localizedDescription, privacy: .public)")
        }
        saveList()
        defaults.set(account.serverURL, forKey: Self.lastServerKey)
        defaults.set(account.serverName, forKey: Self.lastServerNameKey)
        defaults.set(account.userName, forKey: Self.lastUserNameKey)
        self.account = account
        self.client = client
        savedSignInProblem = nil
    }

    private func saveList() {
        do {
            defaults.set(try JSONEncoder().encode(saved), forKey: Self.savedKey)
        } catch {
            Self.log.error("Couldn't save the sign-ins: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Signs out of the sign-in in use; see `signOut(of:beforeTellingServer:)`.
    func signOut(beforeTellingServer: @escaping @Sendable () async -> Void = {}) {
        guard let account else {
            defaults.removeObject(forKey: Self.accountKey)
            client = nil
            return
        }
        signOut(of: account, beforeTellingServer: beforeTellingServer)
    }

    /// Signs out of a sign-in kept here at once, then tells the server in the background, after
    /// `beforeTellingServer` has finished what still needs the sign-in there. Neither is waited
    /// for: a server out of reach keeps a token no one uses, rather than keeping the app signed in
    /// while it's asked. Signing out of the one in use leaves none in use, whatever others are
    /// kept: which comes next is the person's to choose.
    func signOut(of account: Account, beforeTellingServer: @escaping @Sendable () async -> Void = {}) {
        let isInUse = account.isSame(as: self.account)
        var client = isInUse ? self.client : nil
        if !isInUse, let token = try? Self.token(of: account, in: tokens) {
            client = JellyfinClient(serverURL: account.serverURL, deviceId: deviceId, deviceName: Device.ownName, token: token)
        }
        do {
            try tokens.delete(account.tokenKey)
            #if os(iOS) || os(macOS)
            // Where the token stays while it can't be moved to the app group.
            try Keychain.deleteAppToken(for: account.serverId)
            #endif
        } catch {
            Self.log.error("Couldn't delete the token of \(account.serverTitle, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        saved.removeAll { $0.isSame(as: account) }
        saveList()
        forgetting(account)
        if isInUse {
            defaults.removeObject(forKey: Self.accountKey)
            self.account = nil
            self.client = nil
        }
        guard let client else { return }
        let endSession = endSession
        let timeLimit = Self.signOutTimeLimit
        Task.detached {
            try? await withTimeLimit(timeLimit) {
                await beforeTellingServer()
                try await endSession(client)
            }
        }
    }
}

/// Why a sign-in kept on this device couldn't be switched to.
nonisolated enum AccountError: LocalizedError, Equatable {
    case notKept(AccountStore.Account)
    case tokenMissing(AccountStore.Account)

    var errorDescription: String? {
        switch self {
        case .notKept(let account):
            "\(account.userName) isn't signed in to \(account.serverTitle) here any more. Sign in again to use it."
        case .tokenMissing(let account):
            "The sign-in to \(account.serverTitle) as \(account.userName) isn't in the Keychain any more. Sign in again to use it."
        }
    }
}

/// Someone a server lists on its sign-in screen, from `/Users/Public`.
nonisolated struct PublicUser: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let primaryImageTag: String?
    /// Whether signing in as them takes a password. A server that doesn't say is taken to want one.
    let hasPassword: Bool

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", primaryImageTag = "PrimaryImageTag", hasPassword = "HasPassword"
    }

    init(id: String, name: String, primaryImageTag: String? = nil, hasPassword: Bool = true) {
        self.id = id
        self.name = name
        self.primaryImageTag = primaryImageTag
        self.hasPassword = hasPassword
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        primaryImageTag = try container.decodeIfPresent(String.self, forKey: .primaryImageTag)
        hasPassword = try container.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? true
    }
}

/// What `operation` gives, unless `limit` passes first: then it's cancelled, and this throws
/// `URLError(.timedOut)`, as a request that takes too long does.
nonisolated func withTimeLimit<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw URLError(.timedOut)
        }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

#if os(iOS) || os(macOS)
// MARK: Sharing the sign-in with the widgets

extension AccountStore {
    /// What the sign-in keeps in defaults, all of it moved to the app group.
    nonisolated static let sharedKeys = [accountKey, savedKey, deviceIdKey, lastServerKey, lastServerNameKey, lastUserNameKey]

    /// Moves a sign-in kept where only the app reads it, its own defaults and Keychain item, to
    /// the app group. It runs at each launch and does nothing once everything has moved.
    static func moveSignInToAppGroup(from appDefaults: UserDefaults, to sharedDefaults: UserDefaults) throws {
        try moveSignIn(from: appDefaults, to: sharedDefaults, isInAppGroup: AppGroup.container != nil) { serverId in
            try moveToken(
                read: { try Keychain.appToken(for: serverId) },
                readShared: { try Keychain.token(for: serverId) },
                writeShared: { try Keychain.setToken($0, for: serverId) },
                deleteOriginal: { try Keychain.deleteAppToken(for: serverId) }
            )
        }
    }

    /// Moves the token of the sign-in first, the app's own if it has one, then the defaults, and
    /// those only once the group has proven itself. A build the group isn't granted to, as one
    /// built without signing or a Mac app whose profile lacks the group, has no container on
    /// iPhone and iPad, and the Keychain refuses it the group everywhere; its group defaults are
    /// a file of the app's own, which a build that has the group never reads, so a sign-in moved
    /// there would be lost to it.
    nonisolated static func moveSignIn(from appDefaults: UserDefaults, to sharedDefaults: UserDefaults, isInAppGroup: Bool,
                                       movingToken: (_ serverId: String) throws -> Void) throws {
        guard isInAppGroup else { throw SignInMoveError.notInAppGroup }
        if let account = try savedAccount(in: appDefaults) ?? savedAccount(in: sharedDefaults) {
            try movingToken(account.serverId)
        }
        moveDefaults(from: appDefaults, to: sharedDefaults)
    }

    /// Moves each of the sign-in's values in the app's own defaults to the group's. Anything left
    /// in the app's own was written there after an earlier move, by a build that kept it there,
    /// so it replaces what the group holds.
    nonisolated static func moveDefaults(from appDefaults: UserDefaults, to sharedDefaults: UserDefaults) {
        for key in sharedKeys {
            guard let value = appDefaults.object(forKey: key) else { continue }
            sharedDefaults.set(value, forKey: key)
            appDefaults.removeObject(forKey: key)
        }
    }

    /// Copies the token from where it is to the shared place, unless it's there already, reads the
    /// copy back, and deletes the original only once the copy reads back the same.
    nonisolated static func moveToken(read: () throws -> String?, readShared: () throws -> String?,
                                      writeShared: (String) throws -> Void, deleteOriginal: () throws -> Void) throws {
        guard let token = try read() else { return }
        if try readShared() != token {
            try writeShared(token)
            guard try readShared() == token else { throw SignInMoveError.copyDiffers }
        }
        try deleteOriginal()
    }
}

nonisolated enum SignInMoveError: LocalizedError {
    case notInAppGroup
    case copyDiffers

    var errorDescription: String? {
        switch self {
        case .notInAppGroup: "This build of vinnyfin isn't in the app group \(AppGroup.identifier)."
        case .copyDiffers: "The Keychain's copy of the sign-in didn't read back the same."
        }
    }
}
#endif
