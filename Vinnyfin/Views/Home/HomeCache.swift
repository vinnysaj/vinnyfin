import CryptoKit
import Foundation
import OSLog

/// Home as it last loaded for a sign-in: its rows and their titles, and the banner's, to draw at
/// once the next time Home opens, before the server has answered or when it can't.
nonisolated struct HomeSnapshot: Codable, Equatable, Sendable {
    var rows: [HomeRow]
    /// The titles of the rows that had loaded.
    var items: [HomeRow.ID: [JellyfinItem]]
    var givenWay: Set<HomeRow.ID>
    var truncated: Set<HomeRow.ID>
    var featured: [JellyfinItem]
    /// The episode each featured show plays.
    var featuredEpisodes: [String: JellyfinItem]
    /// What picked the rows chosen at random.
    var randomSeed: UInt64
    var savedAt: Date
}

/// Where one sign-in's `HomeSnapshot` is kept: a file of its own, sealed with a key made from
/// the sign-in's token, so another sign-in on this device can't read it, and one signed in again
/// (with a new token) or signed out finds nothing. Signing out deletes it (`drop(for:)`).
nonisolated struct HomeCache: Sendable {
    let file: URL
    private let key: SymmetricKey

    /// Where Home caches are kept: out of backups, as they're the server's to give again.
    static let directory = URL.applicationSupportDirectory.appending(path: "Home", directoryHint: .isDirectory)
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "home")

    /// The cache of the signed-in `session`; nil without a token to seal it with.
    init?(_ session: ServerSession, directory: URL = HomeCache.directory) {
        guard let token = session.client.token, !token.isEmpty else { return nil }
        file = Self.file(for: session.account, in: directory)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                                     salt: Data(session.account.tokenKey.utf8),
                                     info: Data("vinnyfin home".utf8), outputByteCount: 32)
    }

    /// The account's file, named by a digest of its server's and user's ids, so the names on
    /// disk say nothing of who's signed in.
    static func file(for account: AccountStore.Account, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(account.tokenKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest + ".home")
    }

    /// The snapshot last saved, or nil when there's none this sign-in can open.
    func load() -> HomeSnapshot? {
        guard let sealed = try? Data(contentsOf: file) else { return nil }
        do {
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
            return try JSONDecoder().decode(HomeSnapshot.self, from: data)
        } catch {
            // Sealed for an earlier sign-in's token, or from an older build: the next save replaces it.
            Self.log.info("Home's saved rows couldn't be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Saves `snapshot` in the background, after anything asked of the caches before.
    func save(_ snapshot: HomeSnapshot) {
        Self.files.async {
            do {
                try write(snapshot)
            } catch {
                Self.log.error("Couldn't save Home's rows: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Saves `snapshot` now.
    func write(_ snapshot: HomeSnapshot) throws {
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(snapshot), using: key)
        guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        try data.write(to: file, options: .atomic)
    }

    /// Saves and deletions, one at a time in the order they're asked for: a deletion as a sign-in
    /// ends comes after any save asked for before it.
    private static let files = DispatchQueue(label: "net.vinnysaj.vinnyfin.home-cache")

    /// Deletes the account's snapshot, as it signs out, once any save of it under way is done.
    static func drop(for account: AccountStore.Account, in directory: URL = HomeCache.directory) {
        let file = file(for: account, in: directory)
        files.sync { remove(file) }
    }

    /// Deletes every snapshot but those of `kept`: one saved as a sign-in ended, after its
    /// deletion, can't be opened by anyone, and goes too.
    static func keepOnly(_ kept: [AccountStore.Account], in directory: URL = HomeCache.directory) {
        let keep = Set(kept.map { file(for: $0, in: directory).lastPathComponent })
        files.async {
            let saved = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in saved where file.pathExtension == "home" && !keep.contains(file.lastPathComponent) { remove(file) }
        }
    }

    private static func remove(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch CocoaError.fileNoSuchFile {
            // Never saved.
        } catch {
            log.error("Couldn't delete Home's saved rows: \(error.localizedDescription, privacy: .public)")
        }
    }
}
