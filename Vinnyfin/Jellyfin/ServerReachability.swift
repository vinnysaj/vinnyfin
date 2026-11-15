import Foundation
import Observation
import OSLog

/// Whether the signed-in server answers. A network that's up says nothing of the server: one at
/// home doesn't answer from outside it, nor one behind a VPN that's down, and the requests sent
/// to it wait out their full timeouts before they fail. So the server is asked a quick question
/// (`/System/Info/Public`) that has `timeLimit` to come back: as the app opens, as it comes back
/// from the background, for another sign-in, when the network changes, on Try Again, and when a
/// screen's request fails; while it doesn't answer, again every `retryInterval`. The screens go
/// by what it last said rather than wait out their requests.
@MainActor @Observable
final class ServerReachability {
    nonisolated enum State: Equatable, Sendable {
        /// Not asked yet for the sign-in in use.
        case unknown
        case reachable
        /// Didn't answer, or something else answered in its place.
        case outOfReach(Absence)
    }

    /// Why the server is out of reach.
    nonisolated enum Absence: Equatable, Sendable {
        /// This device has no network at all.
        case deviceOffline
        /// Nothing answered at the server's address in time, or the connection was refused.
        case noAnswer
        /// Something other than the server answered at its address: another Jellyfin server, or
        /// a web page, as a hotel network's sign-in page is.
        case somethingElseAnswers
        /// The server, or a proxy in front of it, answered with an error.
        case failing(status: Int)
    }

    /// What the server last said, for the sign-in `signIn`.
    private(set) var state = State.unknown
    /// The sign-in `state` is about, its `AccountStore.Account.tokenKey`.
    private(set) var signIn: String?
    /// A question is out to the server.
    private(set) var isChecking = false

    /// Whether the server is known not to answer. Until it has been asked, it's taken to answer.
    var isOutOfReach: Bool {
        if case .outOfReach = state { true } else { false }
    }

    /// How long the server has to answer. One on the same network answers in well under a
    /// second, and one across the internet in a second or two.
    nonisolated static let timeLimit = Duration.seconds(4)
    /// How often a server out of reach is asked again while the app is open.
    nonisolated static let retryInterval = Duration.seconds(15)

    /// Asks the server at `client`'s address whether it's there: throws when it doesn't answer
    /// in time or isn't the one with `serverId`.
    typealias Ask = @Sendable (_ client: JellyfinClient, _ serverId: String) async throws -> Void

    @ObservationIgnored private let ask: Ask
    @ObservationIgnored private let timeLimit: Duration
    @ObservationIgnored private let retryInterval: Duration
    /// Changes of the network the device is on.
    @ObservationIgnored private let networkChanges: @Sendable () -> AsyncStream<Void>
    /// The question out, which a second check waits on rather than asking again.
    @ObservationIgnored private var question: Task<Void, Never>?
    @ObservationIgnored private var session: ServerSession?
    nonisolated private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "reachability")

    init(timeLimit: Duration = ServerReachability.timeLimit, retryInterval: Duration = ServerReachability.retryInterval,
         networkChanges: @escaping @Sendable () -> AsyncStream<Void> = StreamingNetwork.changes,
         ask: @escaping Ask = ServerReachability.askServer) {
        self.timeLimit = timeLimit
        self.retryInterval = retryInterval
        self.networkChanges = networkChanges
        self.ask = ask
    }

    /// Keeps `state` up to date for `session` until the calling task is cancelled: asks at once,
    /// again whenever the network changes, and every `retryInterval` while the server doesn't
    /// answer. Signed out, it forgets what it knew.
    func follow(_ session: ServerSession?) async {
        guard let session else {
            adopt(nil)
            return
        }
        adopt(session)
        let changes = networkChanges()
        let onNetworkChange = Task { [weak self] in
            for await _ in changes { await self?.check() }
        }
        defer { onNetworkChange.cancel() }
        await check()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: retryInterval)
            } catch {
                return
            }
            if isOutOfReach { await check() }
        }
    }

    /// Asks the server now, as Try Again does, and waits for the answer; with a question already
    /// out, waits for that one's.
    func check() async {
        guard let session else { return }
        if let question {
            await question.value
            return
        }
        let signIn = session.account.tokenKey
        let ask = ask
        let timeLimit = timeLimit
        let question = Task { @MainActor in
            isChecking = true
            defer { isChecking = false }
            let answer = await Self.outcome(of: session, ask: ask, timeLimit: timeLimit)
            // A question asked for another sign-in, or cut short, says nothing of this one.
            guard let answer, self.signIn == signIn else { return }
            if answer != state {
                Self.log.info("Server \(answer == .reachable ? "answers" : "is out of reach", privacy: .public)")
            }
            state = answer
        }
        self.question = question
        await question.value
        if self.question == question { self.question = nil }
    }

    /// Takes up `session`'s sign-in, forgetting what was known of another's.
    private func adopt(_ session: ServerSession?) {
        let signIn = session?.account.tokenKey
        self.session = session
        guard signIn != self.signIn else { return }
        question?.cancel()
        question = nil
        self.signIn = signIn
        state = .unknown
    }

    /// What asking the server comes to; nil when the question was cancelled.
    nonisolated static func outcome(of session: ServerSession, ask: @escaping Ask, timeLimit: Duration) async -> State? {
        let client = session.client
        let serverId = session.account.serverId
        do {
            try await withTimeLimit(timeLimit) { try await ask(client, serverId) }
            return .reachable
        } catch {
            if Task.isCancelled { return nil }
            return .outOfReach(absence(for: error))
        }
    }

    /// Why a question to the server failed.
    nonisolated static func absence(for error: any Error) -> Absence {
        switch error {
        case let error as URLError where [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code):
            .deviceOffline
        case JellyfinError.notJellyfin, is ServerMismatch:
            .somethingElseAnswers
        case JellyfinError.http(let status, _):
            .failing(status: status)
        default:
            .noAnswer
        }
    }

    /// Another server answered at the address: one that isn't the one signed in to.
    nonisolated struct ServerMismatch: Error {}

    /// Asks the server for its public details, which take no sign-in, and checks they're its own.
    nonisolated static func askServer(_ client: JellyfinClient, serverId: String) async throws {
        let info = try await client.publicSystemInfo()
        guard info.id == serverId else { throw ServerMismatch() }
    }
}

extension ServerReachability.Absence {
    /// Why, in a sentence for the screen: "Showcase doesn't answer. It may be off, or on
    /// another network."
    func explanation(server: String) -> String {
        switch self {
        case .deviceOffline:
            "This \(Device.name) isn't connected to the internet."
        case .noAnswer:
            "\(server) doesn't answer. It may be off, or on another network."
        case .somethingElseAnswers:
            "Something other than \(server) answers at its address, such as a network's sign-in page."
        case .failing(let status):
            "\(server) answers with an error (HTTP \(status))."
        }
    }
}
