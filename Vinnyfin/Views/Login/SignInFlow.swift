import Foundation

/// The sign-in screen's two steps, what's entered in them, and where each outcome takes them.
/// The account step asks who is signing in and the server step where. Someone new starts on the
/// server step, which finds the servers on the network, then signs in on the account step of
/// the one picked. Anyone who has signed in before, on this device or another of theirs, starts
/// on the account step, the server picked when they've used one here: that's also where the
/// demo account signs in, from the server step's way to the username first. A sign-in that fails
/// goes to the step whose fields can put it right, and names the field that needs attention
/// there.
nonisolated struct SignInFlow: Sendable {
    enum Step: Hashable, Sendable {
        case account, server
    }

    /// Return moves through each step's fields in this order, and signs in from the last.
    enum Field: Hashable, Sendable {
        case username, password, host, port, path
    }

    /// The server the account step signs in to, and what it's called there.
    struct PickedServer: Equatable, Sendable {
        var address: ServerAddress
        var url: URL
        var title: String
    }

    /// What a sign-in asks of the server once it answers.
    enum Goal: Equatable, Sendable {
        /// Signing in, with the username and password as they were when it started.
        case password(username: String, password: String)
        /// A Quick Connect code to approve on a device that's signed in.
        case quickConnect
        /// Only its answer, so that the account step signs in to it.
        case server
    }

    /// One sign-in: the address it goes to, and what for.
    struct Attempt: Equatable, Sendable {
        var address: ServerAddress
        var goal: Goal
        /// The demo account's, whose errors stay on the account step: its server has no fields
        /// to put right.
        var isDemo = false
    }

    /// What a step's button leads to: a sign-in to run, or a field to fill in first.
    enum Next: Equatable, Sendable {
        case attempt(Attempt)
        case focus(Field)
    }

    /// What a sign-in was doing when it failed.
    enum Stage: Sendable {
        /// Waiting for a server to answer at the address.
        case findingServer
        /// Signing in to the server that answered, or getting its Quick Connect code approved.
        case signingIn
    }

    /// What a failure says is wrong, which says the step to put it right on.
    private enum Problem: Equatable {
        /// No Jellyfin server answers at the address, or it isn't an address; the field is the
        /// one at fault.
        case address(Field)
        case credentials
        case quickConnectOff
        case other
    }

    /// What the server answering an attempt leads to.
    enum Answered: Equatable, Sendable {
        /// Signing in to it as the attempt's goal says, the attempt going on at the address the
        /// server answered at.
        case signIn(Attempt)
        /// The attempt wanted only the server, which is picked now: the account step, with the
        /// cursor in the field.
        case picked(Field)
        /// The server step's fields have moved on from the attempt's address, so it ends there,
        /// without its answer.
        case stale
    }

    /// Why nothing answered at an address, as what to do about it.
    struct Trouble: Equatable, Sendable {
        var message: String
        /// HTTPS failed at an address that gives it, so HTTP may do.
        var offersHTTP = false
    }

    /// What advice calls this device: "is this iPhone on the same network?"
    let deviceName: String
    /// The step the screen opens on, under the other when that's shown.
    private(set) var root = Step.account
    private(set) var step = Step.account
    /// Whether the server step's button gets a Quick Connect code, rather than signing in with
    /// the password.
    private(set) var isQuickConnect = false
    var username = ""
    var password = ""
    /// The server step's address, as its field and Advanced's fields give it. The screen
    /// changes it through `typeAddress` and `editAddress`, which keep `addressText` with it.
    var address = ServerAddress()
    /// What the server step's address field shows: the whole address as typed, or as one line
    /// once it comes from elsewhere (`ServerAddress.text`).
    private(set) var addressText = ""
    private(set) var pickedServer: PickedServer?
    private(set) var accountError: String?
    /// The server step's error, with the address it's about.
    private var serverProblem: (trouble: Trouble, address: ServerAddress)?
    /// Quick Connect is off on the server, so the server step offers the password in its place.
    private(set) var offersPassword = false
    private var hasStarted = false

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// The server step's error, while the address is the one it's about.
    var serverError: String? {
        guard let serverProblem, serverProblem.address == address else { return nil }
        return serverProblem.trouble.message
    }

    /// The server step's error is that the address's HTTPS failed, so the step offers HTTP.
    var offersHTTP: Bool {
        guard let serverProblem, serverProblem.address == address else { return false }
        return serverProblem.trouble.offersHTTP
    }

    /// The username as it's sent, without the spaces around it.
    var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the account step's button signs in, to the demo server or the server picked,
    /// rather than going on to ask for the server.
    var accountStepSignsIn: Bool {
        pickedServer != nil || Self.isDemoAccount(username: username, password: password)
    }

    // MARK: Starting

    /// Starts from a server offered to sign in to, such as the one a handed-off title is from,
    /// with its password if there's one saved; else, adding a sign-in, from the server of the one
    /// in use, for someone else on it; else from the last sign-in on this device, called by the
    /// server's name when it had one. With none of those, and no servers signed in to on the
    /// person's devices (`knowsServers`), it's someone new, who starts on the server step. Only
    /// the first call does, so the screen appearing again leaves what's been entered.
    mutating func start(offer: ServerSignIn?, password: String?, adding: AccountStore.Account? = nil, lastServerURL: URL?,
                        lastServerName: String?, lastUserName: String?, knowsServers: Bool = true) -> Next? {
        guard !hasStarted else { return nil }
        hasStarted = true
        if let offer { return choose(offer, password: password) }
        if let adding, let address = ServerAddress(savedURL: adding.serverURL) {
            pickedServer = PickedServer(address: address, url: adding.serverURL, title: adding.serverTitle)
            return nil
        }
        if let lastServerURL, let address = ServerAddress(savedURL: lastServerURL) {
            pickedServer = PickedServer(address: address, url: lastServerURL, title: lastServerName ?? Self.title(of: lastServerURL))
        }
        username = lastUserName ?? ""
        if pickedServer == nil, username.isEmpty, !knowsServers {
            root = .server
            show(.server)
        }
        return nil
    }

    /// What to call a server without a name: its host, and its port when the address gives one.
    static func title(of url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Picks a server someone signed in to, with their username. With the password they saved in
    /// iCloud on any of their devices, it signs in; without one, the password is next.
    mutating func choose(_ signIn: ServerSignIn, password: String?) -> Next? {
        guard let address = ServerAddress(savedURL: signIn.address) else {
            accountError = "\(signIn.address.absoluteString) isn't a server address vinnyfin can use."
            return nil
        }
        show(.account)
        pickedServer = PickedServer(address: address, url: signIn.address, title: signIn.serverTitle)
        username = signIn.userName
        self.password = password ?? ""
        guard password != nil else { return .focus(.password) }
        return begin(Attempt(address: address, goal: credentials))
    }

    // MARK: The account step

    /// The account step's button. The demo account signs in to the demo server, and any other to
    /// the server picked; without one, the server step asks for its address.
    mutating func submitAccount() -> Next {
        guard !trimmedUsername.isEmpty else { return .focus(.username) }
        if Self.isDemoAccount(username: username, password: password) {
            return begin(Attempt(address: Self.demoServer, goal: .password(username: Self.demoUserName, password: password),
                                 isDemo: true))
        }
        if let pickedServer { return begin(Attempt(address: pickedServer.address, goal: credentials)) }
        show(.server)
        return .focus(.host)
    }

    /// Someone the picked server lists on its sign-in screen: their name in the username, and
    /// the password next, or for someone without one, the sign-in.
    mutating func chooseUser(_ user: PublicUser) -> Next {
        username = user.name
        password = ""
        guard user.hasPassword else { return submitAccount() }
        accountError = nil
        return .focus(.password)
    }

    /// Says on the account step why something else it offers didn't work, such as switching to
    /// a sign-in kept on this device.
    mutating func showAccountError(_ message: String) {
        show(.account)
        accountError = message
    }

    /// Quick Connect from the account step: a code from the server picked, or without one, the
    /// server step asks for its address.
    mutating func useQuickConnect() -> Next {
        if let pickedServer { return begin(Attempt(address: pickedServer.address, goal: .quickConnect)) }
        show(.server, quickConnect: true)
        return .focus(.host)
    }

    /// The server step, to change the server picked, starting from its address.
    mutating func changeServer() -> Field {
        if let pickedServer { setAddress(pickedServer.address) }
        show(.server)
        return .host
    }

    /// Someone who knows their account but not yet the server's address, or has the demo
    /// account, goes from the server step to the account step without a server picked.
    mutating func useUsernameFirst() -> Field {
        show(.account)
        return .username
    }

    // MARK: The server step

    /// What's typed in the server step's address field, as the whole address: the protocol, port
    /// and base path it gives, and none it doesn't. An address copied from a browser showing
    /// Jellyfin's web app is at its base path (`ServerAddress(parsing:)`). The field keeps the
    /// text as it's typed, so "nas:8096" isn't cut apart at "nas:".
    mutating func typeAddress(_ text: String) {
        addressText = text
        address = ServerAddress(parsing: text) ?? ServerAddress(host: text)
    }

    /// Changes the address in Advanced's fields; the address field shows the result.
    mutating func editAddress(_ change: (inout ServerAddress) -> Void) {
        var address = address
        change(&address)
        setAddress(address)
    }

    /// Picks a server found on the network, as if its address were typed and connected to.
    mutating func pick(_ server: DiscoveredServer) -> Next {
        setAddress(ServerAddress(savedURL: server.address) ?? ServerAddress(host: server.address.absoluteString))
        return connect()
    }

    private mutating func setAddress(_ address: ServerAddress) {
        self.address = address
        addressText = address.text
    }

    /// The server step's button. Once a server answers at the address, the password signs in to
    /// it or Quick Connect gets a code from it; without a username, the account step asks for one.
    mutating func connect() -> Next {
        address.splitHost()
        setAddress(address)
        if case .failure(let problem) = address.url {
            show(.server, quickConnect: isQuickConnect)
            serverProblem = (Trouble(message: problem.localizedDescription), address)
            return .focus(Self.field(for: problem))
        }
        let goal = isQuickConnect ? .quickConnect : trimmedUsername.isEmpty ? .server : credentials
        return begin(Attempt(address: address, goal: goal))
    }

    /// Back to the step under this one, with the server as it was picked.
    mutating func back() {
        show(root)
    }

    /// The password in place of Quick Connect, which is off on the server: the account step, with
    /// the server picked.
    mutating func usePassword() -> Field {
        show(.account)
        return trimmedUsername.isEmpty ? .username : .password
    }

    // MARK: Outcomes

    /// Whether an attempt no longer goes with the screen: the server step's fields give another
    /// address than the attempt's. What comes of it then is no one's to see, and its sign-in no
    /// one's to make.
    func isStale(_ attempt: Attempt) -> Bool {
        step == .server && address != attempt.address
    }

    /// The server answered at `address`: it's the one the account step signs in to, and the
    /// server step keeps the address it answered at. An attempt for the server alone ends on the
    /// account step, for the username.
    mutating func found(_ server: AccountStore.Server, at address: ServerAddress, for attempt: Attempt) -> Answered {
        guard !attempt.isDemo else { return .signIn(attempt) }
        guard !isStale(attempt) else { return .stale }
        pickedServer = PickedServer(address: address, url: server.url, title: server.title)
        if step == .server { setAddress(address) }
        guard attempt.goal == .server else { return .signIn(Attempt(address: address, goal: attempt.goal)) }
        show(.account)
        return .picked(.username)
    }

    /// Shows why an attempt failed on the step whose fields can put it right, and names the field
    /// that needs attention there. An address no Jellyfin server answers at goes to the server
    /// step, with the address in its fields; a wrong username or password goes to the account
    /// step, the server staying picked; Quick Connect turned off goes to the server step, which
    /// offers the password in its place. Anything else stays where it is, as do all of the demo
    /// account's errors. A stale attempt's failure shows nowhere.
    mutating func fail(_ attempt: Attempt, while stage: Stage, with error: any Error) -> Field? {
        guard !isStale(attempt) else { return nil }
        let trouble = Self.trouble(error, at: attempt.address, on: deviceName)
        let problem = Self.problem(in: error, while: stage)
        if attempt.isDemo {
            accountError = trouble.message
            return problem == .credentials ? .password : nil
        }
        switch problem {
        case .address(let field):
            setAddress(attempt.address)
            show(.server, quickConnect: attempt.goal == .quickConnect)
            serverProblem = (trouble, attempt.address)
            return field
        case .credentials:
            show(.account)
            accountError = trouble.message
            return .password
        case .quickConnectOff:
            setAddress(attempt.address)
            show(.server, quickConnect: true)
            serverProblem = (trouble, attempt.address)
            offersPassword = true
            return nil
        case .other:
            switch step {
            case .account: accountError = trouble.message
            case .server: serverProblem = (trouble, attempt.address)
            }
            return nil
        }
    }

    /// The server step's address on HTTP, for a server whose HTTPS failed.
    mutating func useHTTP() {
        editAddress { $0.choose(.http) }
    }

    /// What went wrong reaching the server at `address`, said as what to do about it: the system's
    /// own words say what failed ("A server with the specified hostname could not be found."),
    /// not what might put it right. Any other error says what it says.
    static func trouble(_ error: any Error, at address: ServerAddress, on deviceName: String) -> Trouble {
        guard let error = error as? URLError else { return Trouble(message: error.localizedDescription) }
        let host = address.host.trimmingCharacters(in: .whitespaces)
        // An address without a scheme has been asked on HTTP already.
        let offersHTTP = address.scheme == .https && address.fallback == nil
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return Trouble(message: "Couldn't find “\(host)”. Check the spelling.")
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            return Trouble(message: "Nothing answered. Is the server on, and is this \(deviceName) on the same network?")
        case .secureConnectionFailed:
            return Trouble(message: "This server doesn't answer on HTTPS.", offersHTTP: offersHTTP)
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid:
            return Trouble(message: "This server's certificate for HTTPS isn't one this \(deviceName) trusts.", offersHTTP: offersHTTP)
        default:
            return Trouble(message: error.localizedDescription)
        }
    }

    private static func problem(in error: any Error, while stage: Stage) -> Problem {
        switch (stage, error) {
        case (.findingServer, let problem as ServerAddress.Problem): .address(field(for: problem))
        case (.findingServer, _): .address(.host)
        case (.signingIn, JellyfinError.invalidCredentials): .credentials
        case (.signingIn, JellyfinError.quickConnectDisabled): .quickConnectOff
        case (.signingIn, _): .other
        }
    }

    private static func field(for problem: ServerAddress.Problem) -> Field {
        problem == .invalidPort ? .port : .host
    }

    private var credentials: Goal { .password(username: trimmedUsername, password: password) }

    /// Starts an attempt; the last one's errors go.
    private mutating func begin(_ attempt: Attempt) -> Next {
        accountError = nil
        serverProblem = nil
        offersPassword = false
        return .attempt(attempt)
    }

    /// Goes to a step, without the errors either step showed.
    private mutating func show(_ step: Step, quickConnect: Bool = false) {
        self.step = step
        isQuickConnect = step == .server && quickConnect
        accountError = nil
        serverProblem = nil
        offersPassword = false
    }

    // MARK: The demo account

    /// The demo server, which App Review signs in to. App Store Connect gives reviewers a username
    /// and password and nothing else, so the demo account signs in there whatever server is picked.
    static let demoServer = ServerAddress(scheme: .https, host: "jftest.vinnysaj.net")
    static let demoUserName = "apple"
    private static let demoPassword = "apple"

    /// Whether the username and password are the demo account's: the username in any case and
    /// without the spaces around it, the password exactly.
    static func isDemoAccount(username: String, password: String) -> Bool {
        username.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(demoUserName) == .orderedSame
            && password == demoPassword
    }
}
