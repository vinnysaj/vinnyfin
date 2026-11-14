#if os(iOS)
import Foundation
import Observation
import OSLog

/// This iPhone or iPad as the remote of a TV: a Mac showing Portable TV, or another app that
/// takes a remote's presses, as Jellyfin's web app does. Presses go through the server, as all
/// of Jellyfin's remote control does, so the TV and the remote need only both reach the server,
/// on the same network or not. The server lists the TVs and what plays on them, asked again
/// every moment while the remote is open.
@Observable
final class TVRemote {
    /// The TVs the server lists now.
    private(set) var televisions: [PlayTarget] = []
    /// The server has answered, or failed to, since the remote opened.
    private(set) var hasLooked = false
    /// Why the server couldn't be asked, or the last press didn't get through.
    private(set) var problem: String?
    /// When the TVs were last seen, which a playback's position counts on from.
    private(set) var seenAt = Date()
    /// Where the pointer is on YouTube, in fractions of the screen from its top left. The TV
    /// shows it where the remote says, so a move lost on the way is made good by the next.
    private(set) var pointer = CGPoint(x: 0.5, y: 0.5)
    /// The TV picked, by its device, which stays picked from one time to the next.
    var chosenDeviceId: String? {
        didSet { defaults.set(chosenDeviceId, forKey: Self.chosenKey) }
    }

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let defaults: UserDefaults
    /// What waits to be sent, in order, while the press before it is on its way.
    @ObservationIgnored private var outbox: [Outgoing] = []
    @ObservationIgnored private var isSending = false
    /// A switch to the library or YouTube made here, which the TV's own word on what it shows
    /// takes a moment to catch up with.
    @ObservationIgnored private var switched: (space: TVSpace, at: Date)?

    private static let chosenKey = "portableTV.remoteDeviceId"
    /// More waiting than this, on a slow connection, and new presses are dropped rather than
    /// played out long after they were made.
    private static let outboxLimit = 12
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "portable-tv")

    init(accounts: AccountStore, defaults: UserDefaults = .standard) {
        self.accounts = accounts
        self.defaults = defaults
        chosenDeviceId = defaults.string(forKey: Self.chosenKey)
        foundFor = Set(defaults.stringArray(forKey: Self.foundKey) ?? [])
    }

    /// The sign-ins, by server and user, a TV has been found for, now or before.
    private var foundFor: Set<String> = []
    private static let foundKey = "portableTV.foundFor"

    /// A TV has been found for the sign-in in use, on this device, now or before: from then on
    /// Home offers the remote, which serves only those with a Mac showing Portable TV, or another
    /// app that takes a remote's presses.
    var hasFoundTV: Bool {
        guard let account = accounts.account else { return false }
        return foundFor.contains(Self.key(for: account))
    }

    /// Asks the server once whether it lists a TV, while none has been found for the sign-in.
    func lookForTV() async {
        guard !hasFoundTV, let client = accounts.client, let account = accounts.account,
              let sessions = try? await client.controllableSessions(userId: account.userId) else { return }
        noteFound(PlayTarget.televisions(from: sessions, excludingDeviceId: accounts.deviceId), for: account)
    }

    private func noteFound(_ televisions: [PlayTarget], for account: AccountStore.Account) {
        let key = Self.key(for: account)
        guard !televisions.isEmpty, !foundFor.contains(key) else { return }
        foundFor.insert(key)
        defaults.set(foundFor.sorted(), forKey: Self.foundKey)
    }

    private static func key(for account: AccountStore.Account) -> String {
        "\(account.serverId).\(account.userId)"
    }

    /// The TV the remote drives: the one picked, else the first listed.
    var target: PlayTarget? {
        televisions.first { $0.session.deviceId == chosenDeviceId } ?? televisions.first
    }

    /// What the TV shows: as switched here just now, else as the TV says.
    var space: TVSpace {
        if let switched, Date.now.timeIntervalSince(switched.at) < 5 { return switched.space }
        return target?.tvSpace ?? .library
    }

    /// Finds the TVs, and how what plays on them is going, until the calling task is cancelled.
    func run() async {
        hasLooked = false
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func refresh() async {
        guard let client = accounts.client, let account = accounts.account else {
            televisions = []
            hasLooked = true
            return
        }
        do {
            let sessions = try await client.controllableSessions(userId: account.userId)
            televisions = PlayTarget.televisions(from: sessions, excludingDeviceId: accounts.deviceId)
            noteFound(televisions, for: account)
            seenAt = .now
            if !isSending { problem = nil }
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("Couldn't find the TVs: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't reach the server: \(error.localizedDescription)"
        }
        hasLooked = true
    }

    // MARK: What plays

    var nowPlaying: JellyfinItem? { target?.session.nowPlayingItem }

    var isPaused: Bool { target?.session.playState.isPaused != false }

    var duration: Double { nowPlaying?.runtimeSeconds ?? 0 }

    /// Where the TV's playback is at `date`, counting on from the last report while it plays.
    func position(at date: Date) -> Double {
        guard let session = target?.session, session.nowPlayingItem != nil else { return 0 }
        var position = session.position
        if !session.playState.isPaused { position += max(0, date.timeIntervalSince(seenAt)) }
        return duration > 0 ? min(position, duration) : position
    }

    // MARK: Presses

    func press(_ press: TVPress) {
        enqueue(.press(press))
    }

    /// Switches the TV to the library or YouTube, each where it was left.
    func show(_ space: TVSpace) {
        switched = (space, .now)
        press(.home(space))
    }

    func playPause() {
        enqueue(.transport(.playPause, seekTo: nil))
    }

    /// Back or ahead by `RemoteCommand.skipInterval`, which the TV skips by.
    func skip(forward: Bool) {
        enqueue(.transport(forward ? .fastForward : .rewind, seekTo: nil))
    }

    func seek(to seconds: Double) {
        enqueue(.transport(.seek, seekTo: max(0, duration > 0 ? min(seconds, duration) : seconds)))
    }

    /// Moves YouTube's pointer by fractions of the screen's width and height.
    func movePointer(dx: Double, dy: Double) {
        pointer = CGPoint(x: min(1, max(0, pointer.x + dx)), y: min(1, max(0, pointer.y + dy)))
        press(.point(x: pointer.x, y: pointer.y))
    }

    func click() {
        press(.click(x: pointer.x, y: pointer.y))
    }

    // MARK: Sending

    private enum Outgoing {
        case press(TVPress)
        case transport(PlaystateCommand, seekTo: Double?)
    }

    /// Sends in order, one at a time. A pointer move waiting is replaced by the next, which says
    /// where the pointer is now, and scrolls waiting add up, so a slow connection lags rather
    /// than backs up.
    private func enqueue(_ item: Outgoing) {
        switch (item, outbox.last) {
        case (.press(.point), .press(.point)?):
            outbox[outbox.count - 1] = item
        case (.press(.scroll(let dx, let dy)), .press(.scroll(let waitingX, let waitingY))?):
            outbox[outbox.count - 1] = .press(.scroll(dx: waitingX + dx, dy: waitingY + dy))
        default:
            guard outbox.count < Self.outboxLimit else { return }
            outbox.append(item)
        }
        guard !isSending else { return }
        isSending = true
        Task { await sendWaiting() }
    }

    private func sendWaiting() async {
        defer { isSending = false }
        while !outbox.isEmpty {
            let item = outbox.removeFirst()
            guard let client = accounts.client, let target else {
                outbox.removeAll()
                return
            }
            do {
                switch item {
                case .press(let press):
                    try await client.send(press.command, toSession: target.id)
                case .transport(let command, let seconds):
                    try await client.send(command, toSession: target.id, seekTo: seconds)
                }
                problem = nil
            } catch {
                guard !error.isCancellation else { continue }
                Self.log.notice("A press didn't get to \(target.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                problem = "\(target.name) didn't get that: \(error.localizedDescription)"
            }
        }
    }
}
#endif
