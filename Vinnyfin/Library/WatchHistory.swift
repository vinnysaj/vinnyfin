import Foundation
import Observation

/// Where playback got to, kept on this device: for local files, which the server knows nothing
/// about, and for server items played while the server couldn't be reached, until it can be
/// told. Server items played online are the server's to remember; they are kept here too so
/// downloaded items show their progress offline.
@Observable
final class WatchHistory {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var position: Double
        var duration: Double?
        var played: Bool
        var updatedAt: Date
        /// The server hasn't been told yet. Only for server items.
        var needsSync: Bool
    }

    /// Positions this close to the start or end count as not started and as watched, matching
    /// Jellyfin's defaults (5% and 90%).
    nonisolated static let minimumResumeFraction = 0.05
    nonisolated static let playedFraction = 0.9

    /// Server items are kept per sign-in, as two people on one server share the items' ids: under
    /// `"<sign-in>|<item id>"`, the sign-in being its `AccountStore.Account.tokenKey`. Files on this
    /// device are everyone's, under their own key. An item kept before sign-ins were told apart is
    /// under its id alone until the sign-in in use takes it over, as it syncs.
    private(set) var entries: [String: Entry] = [:]
    /// Why the history couldn't be loaded or saved, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let file: URL
    /// The sign-in in use, whose server items are the ones read, recorded and sent: its
    /// `AccountStore.Account.tokenKey`, or nil while signed out.
    @ObservationIgnored private let signIn: @MainActor () -> String?

    init(file: URL = URL.applicationSupportDirectory.appending(path: "WatchHistory.json"),
         signIn: @escaping @MainActor () -> String? = { nil }) {
        self.file = file
        self.signIn = signIn
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
        } catch {
            problem = "Couldn't read the watch history: \(error.localizedDescription)"
        }
    }

    /// The key for a file on this device, stable across renames within a folder and moves:
    /// its name and size.
    nonisolated static func fileKey(name: String, size: Int64) -> String {
        "file:\(name):\(size)"
    }

    /// The sign-in in use's entry for a server item, or a file's.
    func entry(for key: String) -> Entry? {
        entries[storageKey(key)] ?? (Self.isFile(key) ? nil : entries[key])
    }

    /// Seconds to resume from, or nil to start at the beginning.
    func resumePosition(for key: String) -> Double? {
        guard let entry = entry(for: key), !entry.played, entry.position > 0 else { return nil }
        return entry.position
    }

    func record(key: String, position: Double, duration: Double?, needsSync: Bool, now: Date = .now) {
        let played = Self.isPlayed(position: position, duration: duration)
        let kept = played ? 0 : Self.isStarted(position: position, duration: duration) ? position : 0
        // A report the server took supersedes anything still queued for it.
        store(Entry(position: kept, duration: duration, played: played, updatedAt: now, needsSync: needsSync), for: key)
    }

    func markPlayed(_ played: Bool, key: String, needsSync: Bool, now: Date = .now) {
        var entry = entry(for: key) ?? Entry(position: 0, duration: nil, played: played, updatedAt: now, needsSync: needsSync)
        entry.played = played
        entry.position = 0
        entry.updatedAt = now
        entry.needsSync = needsSync
        store(entry, for: key)
    }

    /// Keeps `entry` for the sign-in in use, in place of one kept before sign-ins were told apart.
    private func store(_ entry: Entry, for key: String) {
        let stored = storageKey(key)
        entries[stored] = entry
        if stored != key { entries[key] = nil }
        save()
    }

    private static func isFile(_ key: String) -> Bool { key.hasPrefix("file:") }

    /// Where the sign-in in use keeps `key`.
    private func storageKey(_ key: String) -> String {
        guard !Self.isFile(key), let signIn = signIn() else { return key }
        return signIn + "|" + key
    }

    /// Whether the entry kept under `stored` is the sign-in in use's to send: its own, or one
    /// kept before sign-ins were told apart.
    private func belongsToSignInInUse(_ stored: String) -> Bool {
        guard !Self.isFile(stored) else { return false }
        guard let signIn = signIn() else { return !stored.contains("|") }
        return stored.hasPrefix(signIn + "|") || !stored.contains("|")
    }

    /// Gives the sign-in in use the server items kept before sign-ins were told apart.
    private func adoptUnowned() {
        guard let signIn = signIn() else { return }
        let unowned = entries.keys.filter { !Self.isFile($0) && !$0.contains("|") }
        guard !unowned.isEmpty else { return }
        for key in unowned {
            let entry = entries.removeValue(forKey: key)
            let owned = signIn + "|" + key
            if entries[owned] == nil { entries[owned] = entry }
        }
        save()
    }

    /// Sends what the sign-in in use watched offline to its server; other sign-ins' wait for
    /// theirs. Entries stay queued while it can't be reached; one it refuses outright (the item
    /// is gone from the library) is dropped and said so.
    func syncPending(using client: JellyfinClient, userId: String) async {
        adoptUnowned()
        guard let signIn = signIn() else { return }
        let prefix = signIn + "|"
        var refused: [String] = []
        for (stored, entry) in entries where entry.needsSync && stored.hasPrefix(prefix) {
            let itemId = String(stored.dropFirst(prefix.count))
            do {
                try await client.updateUserData(itemId: itemId, userId: userId, UserDataUpdate(
                    positionTicks: Int64(entry.position * 10_000_000), played: entry.played, lastPlayed: entry.updatedAt
                ))
                entries[stored]?.needsSync = false
            } catch JellyfinError.http(let status, let body) where (400..<500).contains(status) && status != 401 && status != 408 && status != 429 {
                entries[stored]?.needsSync = false
                refused.append(JellyfinError.message(status: status, body: body))
            } catch {
                // Offline or the server is down; the next sync tries again.
                continue
            }
        }
        if !refused.isEmpty {
            problem = "The server didn't take what was watched offline for \(refused.count) item(s): \(refused[0])"
        }
        save()
    }

    /// Whether the sign-in in use has anything watched offline still to send.
    var hasPendingSync: Bool { entries.contains { $0.value.needsSync && belongsToSignInInUse($0.key) } }

    nonisolated static func isPlayed(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return position / duration >= playedFraction
    }

    nonisolated static func isStarted(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return position > 30 }
        return position / duration >= minimumResumeFraction
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        } catch {
            problem = "Couldn't save the watch history: \(error.localizedDescription)"
        }
    }
}
