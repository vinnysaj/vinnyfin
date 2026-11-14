import Foundation
import Observation
import OSLog

/// Jellyfin's socket, held open while the app runs in front, signed in. Over it the server
/// passes on what other devices ask this one to play and do, and, while this device is a remote
/// for another, how that one's session is going. While the socket is open, with the
/// capabilities reported, the server lists this device as one others can play to; when it
/// closes, the server drops the session at once, so a device that has gone to the background
/// leaves every Play On list. The server can't wake an app that isn't running.
///
/// Each window that takes commands holds it open (`hold(client:)`): on the Mac, Portable TV's
/// window as well as the library's, so closing one leaves the other's remote working.
@Observable
final class SessionSocket {
    enum State: Equatable {
        case closed
        case connecting
        case open
        /// Why the last attempt failed; another follows after a pause.
        case failed(String)

        var label: String {
            switch self {
            case .closed: "Off"
            case .connecting: "Connecting…"
            case .open: "On"
            case .failed(let reason): "Not Connected: \(reason)"
            }
        }
    }

    private(set) var state = State.closed

    /// What the server is told this device can do; told again as it changes while the socket is open.
    var capabilities = ClientCapabilities() {
        didSet {
            guard capabilities != oldValue, state == .open, let client = openClient else { return }
            report(capabilities, to: client)
        }
    }

    /// Commands from other devices.
    @ObservationIgnored var onCommand: ((RemoteCommand) -> Void)?
    /// The sessions as they change, while `followsSessions` is on.
    @ObservationIgnored var onSessions: (([RemoteSession]) -> Void)?
    /// Asks the server for the sessions as they change, at most once a second.
    var followsSessions = false {
        didSet {
            guard followsSessions != oldValue, state == .open else { return }
            send(followsSessions ? .sessionsStart(delay: 0, interval: 1) : .sessionsStop)
        }
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// The sign-in of the open socket, for capabilities that change while it's open.
    @ObservationIgnored private var openClient: JellyfinClient?
    @ObservationIgnored private var lastReport: Task<Void, Never>?
    /// The windows holding the socket open, oldest first, by the sign-in each holds it for.
    @ObservationIgnored private var holds: [(id: UUID, client: JellyfinClient)] = []
    /// The socket's connection, for the sign-in of the newest hold.
    @ObservationIgnored private var connection: (id: UUID, signIn: String, task: Task<Void, Never>)?
    /// When the server last said anything, in system uptime.
    @ObservationIgnored private var lastHeard: TimeInterval = 0
    /// Half the time the server waits for word before it closes the socket.
    @ObservationIgnored private var keepAliveInterval: Double = 30

    private nonisolated static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "socket")

    /// Holds the socket open until the calling task is cancelled. While others hold it too it
    /// stays open, for the sign-in of the newest.
    func hold(client: JellyfinClient) async {
        let id = UUID()
        holds.append((id, client))
        connectNewestHold()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        holds.removeAll { $0.id == id }
        connectNewestHold()
    }

    /// Runs the socket for the newest hold's sign-in, unless it runs for it already, and closes it
    /// once nothing holds it.
    private func connectNewestHold() {
        let newest = holds.last
        let signIn = newest.map { "\($0.client.serverURL.absoluteString) \($0.client.token ?? "")" }
        guard connection?.signIn != signIn else { return }
        connection?.task.cancel()
        connection = nil
        guard let newest, let signIn else {
            state = .closed
            return
        }
        let id = UUID()
        connection = (id, signIn, Task { await run(client: newest.client, connection: id) })
    }

    /// Keeps the socket open until the task is cancelled, connecting again, after a growing
    /// pause, whenever it fails or the server closes it. Says how it's going while it's still
    /// the socket's `connection`.
    private func run(client: JellyfinClient, connection id: UUID) async {
        func setState(_ new: State) {
            if connection?.id == id { state = new }
        }
        var pause: Double = 1
        while !Task.isCancelled {
            setState(.connecting)
            do {
                try await connect(client, setState: setState)
                pause = 1
            } catch {
                guard !Task.isCancelled else { break }
                Self.log.notice("The socket to \(client.serverURL, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                setState(.failed(error.localizedDescription))
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .seconds(pause))
            pause = min(pause * 2, 30)
        }
        setState(.closed)
    }

    /// Opens the socket, reports what this device can do, and reads it until it closes.
    private func connect(_ client: JellyfinClient, setState: (State) -> Void) async throws {
        let socket = URLSession.shared.webSocketTask(with: client.socketRequest)
        self.socket = socket
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket {
                self.socket = nil
                openClient = nil
            }
        }
        // The server's first word, how long it waits for keep-alives, says the socket is open.
        await handle(try await socket.receive())
        let reported = capabilities
        try await client.reportCapabilities(reported)
        guard self.socket === socket else { return }
        openClient = client
        setState(.open)
        // They changed while the first report was out.
        if capabilities != reported { report(capabilities, to: client) }
        if followsSessions { send(.sessionsStart(delay: 0, interval: 1)) }
        let keepAlive = Task { await keepAlive(socket) }
        defer { keepAlive.cancel() }
        while !Task.isCancelled {
            await handle(try await socket.receive())
        }
    }

    /// Says something every `keepAliveInterval`, and gives up on a socket the server has stopped
    /// answering, which closes without a word when the network goes.
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(keepAliveInterval))
            guard !Task.isCancelled else { return }
            if ProcessInfo.processInfo.systemUptime - lastHeard > keepAliveInterval * 2 + 5 {
                Self.log.notice("The server stopped answering the socket")
                socket.cancel(with: .abnormalClosure, reason: nil)
                return
            }
            send(.keepAlive)
        }
    }

    private func handle(_ received: URLSessionWebSocketTask.Message) async {
        lastHeard = ProcessInfo.processInfo.systemUptime
        let data: Data
        switch received {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        let message: SocketMessage
        do {
            message = try await Self.decode(data)
        } catch {
            // One message the app can't read leaves the socket and the rest of them working.
            Self.log.error("Couldn't read a socket message: \(String(describing: error), privacy: .public)")
            return
        }
        switch message {
        case .forceKeepAlive(let seconds):
            keepAliveInterval = max(5, Double(seconds) / 2)
            send(.keepAlive)
        case .sessions(let sessions):
            onSessions?(sessions)
        case .keepAlive, .other:
            break
        case .play, .playstate, .generalCommand:
            if let command = RemoteCommand(message) {
                Self.log.info("Remote command: \(String(describing: command), privacy: .public)")
                onCommand?(command)
            } else {
                Self.log.notice("Ignored a command this app doesn't obey: \(String(describing: message), privacy: .public)")
            }
        }
    }

    /// Off the main actor: the sessions a remote follows arrive every second.
    @concurrent
    private nonisolated static func decode(_ data: Data) async throws -> SocketMessage {
        try SocketMessage(json: data)
    }

    /// Reports in turn, so the server ends up with the last.
    private func report(_ capabilities: ClientCapabilities, to client: JellyfinClient) {
        let previous = lastReport
        lastReport = Task {
            await previous?.value
            do {
                try await client.reportCapabilities(capabilities)
            } catch {
                Self.log.notice("Couldn't report what this device can do: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func send(_ message: SocketMessage.Outbound) {
        guard let socket else { return }
        socket.send(.string(message.json)) { error in
            // A failed send means the socket is going; reading it fails next, and it reconnects.
            if let error { Self.log.notice("Couldn't send on the socket: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
