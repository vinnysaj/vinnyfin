import Foundation
import Testing
@testable import vinnyfin

private enum SignIn {
    static let home = ServerSignIn(serverId: "home", serverName: "Home", address: URL(string: "http://nas.local:8096")!,
                                   userId: "u1", userName: "Alex")
    static let homeAddress = ServerAddress(scheme: .http, host: "nas.local", port: "8096")

    /// The server that answered at `url`.
    static func server(_ url: String, named name: String? = "Home") -> AccountStore.Server {
        AccountStore.Server(url: URL(string: url)!, info: PublicSystemInfo(serverName: name, version: "10.11.0", id: "home"))
    }

    /// The flow on the account step with `home` picked and its user filled in.
    static func pickedHome() -> SignInFlow {
        var flow = SignInFlow(deviceName: "iPhone")
        _ = flow.start(offer: home, password: nil, lastServerURL: nil, lastServerName: nil, lastUserName: nil)
        return flow
    }

    /// The attempt a step's button starts.
    static func attempt(_ next: SignInFlow.Next) throws -> SignInFlow.Attempt {
        guard case .attempt(let attempt) = next else { throw Unexpected(next: next) }
        return attempt
    }

    struct Unexpected: Error {
        let next: SignInFlow.Next
    }
}

struct DemoAccountTests {
    @Test func signsInToTheDemoServer() throws {
        #expect(try SignInFlow.demoServer.url.get() == URL(string: "https://jftest.vinnysaj.net")!)
        #expect(SignInFlow.demoServer.fallback == nil)
    }

    @Test func knowsTheDemoAccountByItsUsernameInAnyCaseAndItsPasswordExactly() {
        #expect(SignInFlow.isDemoAccount(username: "apple", password: "apple"))
        #expect(SignInFlow.isDemoAccount(username: "  Apple\n", password: "apple"))
        #expect(SignInFlow.isDemoAccount(username: "APPLE", password: "apple"))
        #expect(!SignInFlow.isDemoAccount(username: "apple", password: "Apple"))
        #expect(!SignInFlow.isDemoAccount(username: "apple", password: " apple"))
        #expect(!SignInFlow.isDemoAccount(username: "apple", password: ""))
        #expect(!SignInFlow.isDemoAccount(username: "apples", password: "apple"))
        #expect(!SignInFlow.isDemoAccount(username: "", password: "apple"))
    }

    @Test func theDemoAccountSignsInToTheDemoServerWhateverServerIsPicked() throws {
        var flow = SignIn.pickedHome()
        flow.username = " Apple "
        flow.password = "apple"
        let attempt = try SignIn.attempt(flow.submitAccount())
        #expect(attempt == SignInFlow.Attempt(address: SignInFlow.demoServer, goal: .password(username: "apple", password: "apple"),
                                              isDemo: true))

        var fresh = SignInFlow(deviceName: "iPhone")
        fresh.username = "apple"
        fresh.password = "apple"
        #expect(fresh.accountStepSignsIn)
        #expect(try SignIn.attempt(fresh.submitAccount()).isDemo)
        #expect(fresh.step == .account)
    }

    @Test func theDemoAccountsErrorsStayOnTheAccountStep() throws {
        var flow = SignIn.pickedHome()
        flow.username = "apple"
        flow.password = "apple"
        let attempt = try SignIn.attempt(flow.submitAccount())

        #expect(flow.fail(attempt, while: .findingServer, with: URLError(.cannotFindHost)) == nil)
        #expect(flow.step == .account)
        #expect(flow.accountError == "Couldn't find “jftest.vinnysaj.net”. Check the spelling.")
        #expect(flow.pickedServer?.address == SignIn.homeAddress)

        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials) == .password)
        #expect(flow.step == .account)
    }

    @Test func theDemoServerAnsweringLeavesThePickedServer() throws {
        var flow = SignIn.pickedHome()
        flow.username = "apple"
        flow.password = "apple"
        let attempt = try SignIn.attempt(flow.submitAccount())
        let demo = SignIn.server("https://jftest.vinnysaj.net", named: "Demo")
        #expect(flow.found(demo, at: SignInFlow.demoServer, for: attempt) == .signIn(attempt))
        #expect(flow.pickedServer?.title == "Home")
    }
}

struct SignInFlowTests {
    @Test func startsFromTheOfferedSignInWithTheCursorInThePassword() {
        var flow = SignInFlow(deviceName: "iPhone")
        #expect(flow.start(offer: SignIn.home, password: nil, lastServerURL: URL(string: "http://other.local"), lastServerName: nil, lastUserName: "Sam")
            == .focus(.password))
        #expect(flow.pickedServer == SignInFlow.PickedServer(address: SignIn.homeAddress, url: SignIn.home.address, title: "Home"))
        #expect(flow.username == "Alex")
        #expect(flow.step == .account)
    }

    @Test func startsFromTheLastSignInOnlyOnce() {
        var flow = SignInFlow(deviceName: "iPhone")
        #expect(flow.start(offer: nil, password: nil, lastServerURL: URL(string: "http://nas.local:8096"), lastServerName: "Home",
                           lastUserName: "Alex") == nil)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
        #expect(flow.pickedServer?.title == "Home")
        #expect(flow.username == "Alex")

        flow.username = "Sam"
        _ = flow.start(offer: nil, password: nil, lastServerURL: URL(string: "http://nas.local:8096"), lastServerName: "Home", lastUserName: "Alex")
        #expect(flow.username == "Sam")
    }

    @Test func aLastServerWithoutANameIsCalledByItsHostAndPort() {
        var flow = SignInFlow(deviceName: "iPhone")
        _ = flow.start(offer: nil, password: nil, lastServerURL: URL(string: "http://nas.local:8096"), lastServerName: nil, lastUserName: nil)
        #expect(flow.pickedServer?.title == "nas.local:8096")
        #expect(SignInFlow.title(of: URL(string: "https://jf.example.com/jellyfin")!) == "jf.example.com")
    }

    @Test func choosingAServerPicksItAndFillsInTheUser() {
        var flow = SignInFlow(deviceName: "iPhone")
        flow.password = "typed"
        #expect(flow.choose(SignIn.home, password: nil) == .focus(.password))
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
        #expect(flow.username == "Alex")
        #expect(flow.password.isEmpty)
    }

    @Test func choosingAServerWithItsSavedPasswordSignsIn() throws {
        var flow = SignInFlow(deviceName: "iPhone")
        let chosen = flow.choose(SignIn.home, password: "secret")
        let attempt = try SignIn.attempt(try #require(chosen))
        #expect(attempt == SignInFlow.Attempt(address: SignIn.homeAddress, goal: .password(username: "Alex", password: "secret")))
        #expect(flow.step == .account)
        #expect(flow.password == "secret")

        var offered = SignInFlow(deviceName: "iPhone")
        let started = offered.start(offer: SignIn.home, password: "", lastServerURL: nil, lastServerName: nil, lastUserName: nil)
        #expect(try SignIn.attempt(try #require(started)).goal == .password(username: "Alex", password: ""))
    }

    @Test func aSavedPasswordThatNoLongerWorksAsksForItWithTheServerPicked() throws {
        var flow = SignInFlow(deviceName: "iPhone")
        let chosen = flow.choose(SignIn.home, password: "old")
        let attempt = try SignIn.attempt(try #require(chosen))
        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials) == .password)
        #expect(flow.step == .account)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
        #expect(flow.accountError != nil)
    }

    @Test func theAccountStepSignsInToThePickedServer() throws {
        var flow = SignIn.pickedHome()
        flow.password = "secret"
        #expect(flow.accountStepSignsIn)
        #expect(try SignIn.attempt(flow.submitAccount())
            == SignInFlow.Attempt(address: SignIn.homeAddress, goal: .password(username: "Alex", password: "secret")))
    }

    @Test func withoutAServerTheAccountStepAsksForOneCarryingTheAccount() throws {
        var flow = SignInFlow(deviceName: "iPhone")
        #expect(flow.submitAccount() == .focus(.username))
        #expect(flow.step == .account)

        flow.username = " Alex "
        flow.password = "secret"
        #expect(!flow.accountStepSignsIn)
        #expect(flow.submitAccount() == .focus(.host))
        #expect(flow.step == .server)
        #expect(!flow.isQuickConnect)

        flow.address.host = "https://jf.example.com/jellyfin"
        let attempt = try SignIn.attempt(flow.connect())
        #expect(attempt.goal == .password(username: "Alex", password: "secret"))
        #expect(attempt.address == ServerAddress(scheme: .https, host: "jf.example.com", path: "/jellyfin"))
        #expect(flow.address == attempt.address)
    }

    @Test func anAddressThatIsntOneStaysOnTheServerStepAtTheFieldAtFault() {
        var flow = SignInFlow(deviceName: "iPhone")
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = "nas.local"
        flow.address.port = "99999"
        #expect(flow.connect() == .focus(.port))
        #expect(flow.serverError == ServerAddress.Problem.invalidPort.localizedDescription)
        flow.address.port = ""
        flow.address.host = "nas local"
        #expect(flow.connect() == .focus(.host))
        #expect(flow.step == .server)
    }

    @Test func aPickedServerThatDoesntAnswerGoesToTheServerStepWithItsAddress() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        let error = URLError(.cannotConnectToHost)
        #expect(flow.fail(attempt, while: .findingServer, with: error) == .host)
        #expect(flow.step == .server)
        #expect(!flow.isQuickConnect)
        #expect(flow.address == SignIn.homeAddress)
        #expect(flow.serverError == "Nothing answered. Is the server on, and is this iPhone on the same network?")
        #expect(flow.accountError == nil)
        // The server stays picked, for Back.
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
    }

    @Test func aPickedServerThatIsntJellyfinGoesToTheServerStep() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        let error = JellyfinError.notJellyfin(SignIn.home.address)
        #expect(flow.fail(attempt, while: .findingServer, with: error) == .host)
        #expect(flow.step == .server)
        #expect(flow.serverError == error.localizedDescription)
    }

    @Test func aWrongPasswordOnTheAccountStepStaysThereWithTheCursorInThePassword() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        #expect(flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: attempt) == .signIn(attempt))
        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials) == .password)
        #expect(flow.step == .account)
        #expect(flow.accountError == "Wrong username or password.")
    }

    @Test func aWrongPasswordOnTheServerStepGoesBackToTheAccountWithTheServerPicked() throws {
        var flow = SignInFlow(deviceName: "iPhone")
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = "nas.local"
        let attempt = try SignIn.attempt(flow.connect())
        // Nothing answered on HTTPS, so the server answered at the fallback, which the fields keep.
        let fallback = try #require(attempt.address.fallback)
        let answered = SignInFlow.Attempt(address: fallback, goal: attempt.goal)
        #expect(flow.found(SignIn.server("http://nas.local:8096"), at: fallback, for: attempt) == .signIn(answered))
        #expect(flow.address == fallback)
        #expect(flow.fail(answered, while: .signingIn, with: JellyfinError.invalidCredentials) == .password)
        #expect(flow.step == .account)
        #expect(flow.accountError == "Wrong username or password.")
        #expect(flow.pickedServer == SignInFlow.PickedServer(address: fallback, url: URL(string: "http://nas.local:8096")!, title: "Home"))
        // Signing in again goes to the server that answered.
        #expect(try SignIn.attempt(flow.submitAccount()).address == fallback)
    }

    @Test func aServerThatDoesntAnswerStaysOnTheServerStep() throws {
        var flow = SignInFlow(deviceName: "iPhone")
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = "nas.local"
        let attempt = try SignIn.attempt(flow.connect())
        #expect(flow.fail(attempt, while: .findingServer, with: URLError(.timedOut)) == .host)
        #expect(flow.step == .server)
        #expect(flow.address == ServerAddress(host: "nas.local"))
        #expect(flow.serverError == "Nothing answered. Is the server on, and is this iPhone on the same network?")
        #expect(flow.pickedServer == nil)
        // The error is about that address, and goes as it changes.
        flow.address.host = "nas.lan"
        #expect(flow.serverError == nil)
    }

    @Test func otherErrorsStayOnTheirStep() throws {
        let error = JellyfinError.http(status: 500, body: "")
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        _ = flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: attempt)
        #expect(flow.fail(attempt, while: .signingIn, with: error) == nil)
        #expect(flow.step == .account)
        #expect(flow.accountError == error.localizedDescription)

        _ = flow.changeServer()
        let fromServer = try SignIn.attempt(flow.connect())
        _ = flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: fromServer)
        #expect(flow.fail(fromServer, while: .signingIn, with: error) == nil)
        #expect(flow.step == .server)
        #expect(flow.serverError == error.localizedDescription)
    }

    @Test func theServerStepWithoutAUsernamePicksTheServerForTheAccountStep() throws {
        var flow = SignIn.pickedHome()
        flow.username = ""
        #expect(flow.changeServer() == .host)
        #expect(flow.address == SignIn.homeAddress)
        flow.address.host = "jf.example.com"
        flow.address.port = ""
        let attempt = try SignIn.attempt(flow.connect())
        #expect(attempt.goal == .server)
        let answered = ServerAddress(host: "jf.example.com")
        #expect(flow.found(SignIn.server("http://jf.example.com:8096", named: "Family"), at: answered, for: attempt) == .picked(.username))
        #expect(flow.step == .account)
        #expect(flow.pickedServer?.title == "Family")
        #expect(flow.pickedServer?.address == answered)
    }

    @Test func backKeepsThePickedServerAndChangeStartsFromIt() {
        var flow = SignIn.pickedHome()
        _ = flow.changeServer()
        flow.address.host = "elsewhere.local"
        flow.back()
        #expect(flow.step == .account)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
        _ = flow.changeServer()
        #expect(flow.address == SignIn.homeAddress)
    }

    @Test func quickConnectAsksForTheServerOrGoesStraightToTheCode() throws {
        var fresh = SignInFlow(deviceName: "iPhone")
        #expect(fresh.useQuickConnect() == .focus(.host))
        #expect(fresh.step == .server)
        #expect(fresh.isQuickConnect)
        fresh.address.host = "nas.local"
        #expect(try SignIn.attempt(fresh.connect()).goal == .quickConnect)

        var picked = SignIn.pickedHome()
        #expect(try SignIn.attempt(picked.useQuickConnect()) == SignInFlow.Attempt(address: SignIn.homeAddress, goal: .quickConnect))
        #expect(picked.step == .account)
    }

    @Test func quickConnectTurnedOffOffersThePasswordWithTheServerPicked() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.useQuickConnect())
        _ = flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: attempt)
        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.quickConnectDisabled) == nil)
        #expect(flow.step == .server)
        #expect(flow.isQuickConnect)
        #expect(flow.offersPassword)
        #expect(flow.address == SignIn.homeAddress)
        #expect(flow.serverError == JellyfinError.quickConnectDisabled.localizedDescription)

        #expect(flow.usePassword() == .password)
        #expect(flow.step == .account)
        #expect(!flow.offersPassword)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
    }

    @Test func aQuickConnectServerThatDoesntAnswerStaysInQuickConnect() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.useQuickConnect())
        #expect(flow.fail(attempt, while: .findingServer, with: URLError(.cannotConnectToHost)) == .host)
        #expect(flow.step == .server)
        #expect(flow.isQuickConnect)
        #expect(try SignIn.attempt(flow.connect()).goal == .quickConnect)
    }

    @Test func startingAgainClearsTheLastError() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        _ = flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials)
        _ = flow.submitAccount()
        #expect(flow.accountError == nil)
    }
}

struct StaleSignInTests {
    /// The flow on the server step with an attempt under way at `host`, as Sign In starts it.
    private func attempting(_ host: String) throws -> (SignInFlow, SignInFlow.Attempt) {
        var flow = SignInFlow(deviceName: "iPhone")
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = host
        return (flow, try SignIn.attempt(flow.connect()))
    }

    @Test func editingTheAddressDuringAnAttemptMakesItStale() throws {
        var (flow, attempt) = try attempting("10.255.255.1")
        #expect(!flow.isStale(attempt))
        flow.address.host = "nas.local"
        #expect(flow.isStale(attempt))
        // An attempt from the account step goes with the server picked there, whatever the fields say.
        var picked = SignIn.pickedHome()
        let fromAccount = try SignIn.attempt(picked.submitAccount())
        picked.address.host = "elsewhere.local"
        #expect(!picked.isStale(fromAccount))
    }

    @Test func aStaleAnswerNeitherFillsInTheFieldsNorSignsIn() throws {
        var (flow, attempt) = try attempting("nas.local")
        flow.address.port = "8920"
        let corrected = flow.address
        let fallback = try #require(attempt.address.fallback)
        #expect(flow.found(SignIn.server("http://nas.local:8096"), at: fallback, for: attempt) == .stale)
        #expect(flow.address == corrected)
        #expect(flow.pickedServer == nil)
        #expect(flow.step == .server)
    }

    @Test func aStaleFailureShowsNowhere() throws {
        var (flow, attempt) = try attempting("10.255.255.1")
        flow.address.host = "nas.local"
        #expect(flow.fail(attempt, while: .findingServer, with: URLError(.timedOut)) == nil)
        #expect(flow.serverError == nil)
        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials) == nil)
        #expect(flow.step == .server)
        #expect(flow.accountError == nil)
        // Nor does it show once the fields go back to its address.
        flow.address.host = "10.255.255.1"
        #expect(flow.serverError == nil)
    }

    @Test func anAttemptGoesOnAtTheAddressTheServerAnsweredAt() throws {
        var (flow, attempt) = try attempting("nas.local")
        let fallback = try #require(attempt.address.fallback)
        guard case .signIn(let answered) = flow.found(SignIn.server("http://nas.local:8096"), at: fallback, for: attempt) else {
            Issue.record("The server answering didn't go on to sign in")
            return
        }
        #expect(answered.address == fallback)
        #expect(flow.address == fallback)
        // The fields hold where it answered, which is no edit of them.
        #expect(!flow.isStale(answered))
        #expect(flow.isStale(attempt))
    }
}

struct ServerTroubleTests {
    private let address = ServerAddress(host: "nas.lan")
    private let https = ServerAddress(scheme: .https, host: "nas.lan")

    private func trouble(_ error: any Error, at address: ServerAddress? = nil) -> SignInFlow.Trouble {
        SignInFlow.trouble(error, at: address ?? self.address, on: "iPhone")
    }

    @Test func saysWhatToDoWhenNothingAnswers() {
        #expect(trouble(URLError(.cannotFindHost)).message == "Couldn't find “nas.lan”. Check the spelling.")
        #expect(trouble(URLError(.dnsLookupFailed)).message == "Couldn't find “nas.lan”. Check the spelling.")
        let noAnswer = "Nothing answered. Is the server on, and is this iPhone on the same network?"
        #expect(trouble(URLError(.timedOut)).message == noAnswer)
        #expect(trouble(URLError(.cannotConnectToHost)).message == noAnswer)
        #expect(!trouble(URLError(.timedOut)).offersHTTP)
    }

    @Test func offersHTTPWhereHTTPSFailedAtAnAddressThatGivesIt() {
        #expect(trouble(URLError(.secureConnectionFailed), at: https)
            == SignInFlow.Trouble(message: "This server doesn't answer on HTTPS.", offersHTTP: true))
        #expect(trouble(URLError(.serverCertificateUntrusted), at: https).offersHTTP)
        // Without a scheme, it's been asked on HTTP already.
        #expect(!trouble(URLError(.secureConnectionFailed)).offersHTTP)
        #expect(!trouble(URLError(.secureConnectionFailed), at: ServerAddress(scheme: .http, host: "nas.lan")).offersHTTP)
    }

    @Test func anyOtherErrorSaysWhatItSays() {
        let notJellyfin = JellyfinError.notJellyfin(URL(string: "https://nas.lan")!)
        #expect(trouble(notJellyfin) == SignInFlow.Trouble(message: notJellyfin.localizedDescription))
        #expect(trouble(URLError(.notConnectedToInternet)).message == URLError(.notConnectedToInternet).localizedDescription)
    }

    @Test func theServerStepOffersHTTPAndUseHTTPTakesIt() throws {
        var flow = SignInFlow(deviceName: "iPhone")
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = "https://nas.lan"
        let attempt = try SignIn.attempt(flow.connect())
        _ = flow.fail(attempt, while: .findingServer, with: URLError(.secureConnectionFailed))
        #expect(flow.serverError == "This server doesn't answer on HTTPS.")
        #expect(flow.offersHTTP)
        flow.useHTTP()
        #expect(flow.address == ServerAddress(scheme: .http, host: "nas.lan"))
        #expect(!flow.offersHTTP)
        #expect(flow.serverError == nil)
    }
}

struct BrowserAddressTests {
    @Test func takesTheServerFromAnAddressCopiedFromJellyfinsWebApp() {
        #expect(ServerAddress(parsing: "http://localhost:32768/web/#/home.html") == ServerAddress(scheme: .http, host: "localhost", port: "32768"))
        #expect(ServerAddress(parsing: "https://jf.example.com/jellyfin/web/index.html#!/home")
            == ServerAddress(scheme: .https, host: "jf.example.com", path: "/jellyfin"))
        #expect(ServerAddress(parsing: "nas.local:8096/web/") == ServerAddress(host: "nas.local", port: "8096"))
        #expect(ServerAddress(parsing: "http://nas.local:8096/web/index.html?id=1#!/details")
            == ServerAddress(scheme: .http, host: "nas.local", port: "8096"))
        #expect(ServerAddress(parsing: "http://nas.local:8096/#/home.html") == ServerAddress(scheme: .http, host: "nas.local", port: "8096"))
        // A base path that's itself called "web" is what's before the web app's own.
        #expect(ServerAddress(parsing: "https://jf.example.com/web/web/#/home.html")?.path == "/web")
    }

    @Test func splitsAnAddressCopiedFromABrowserIntoTheFields() throws {
        var typed = ServerAddress(host: "http://localhost:32768/web/#/home.html")
        typed.splitHost()
        #expect(typed == ServerAddress(scheme: .http, host: "localhost", port: "32768"))
        #expect(try typed.url.get() == URL(string: "http://localhost:32768")!)
    }

    @Test func keepsASavedAddressAsItIs() {
        #expect(ServerAddress(savedURL: URL(string: "https://jf.example.com/web")!)?.path == "/web")
    }
}

struct ServerProbeTests {
    @Test func asksBothAtOnceAndTakesHTTPSWhenItAnswersSoonAfterHTTP() async throws {
        let found = try await ServerAddress(host: "nas.local").firstAnswer { url in
            if url.scheme == "https" { try await Task.sleep(for: .milliseconds(300)) }
            return url.scheme ?? ""
        }
        #expect(found.address == ServerAddress(host: "nas.local"))
        #expect(found.answer == "https")
    }

    @Test func takesHTTPOnceHTTPSHasHadItsGrace() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let found = try await ServerAddress(host: "nas.local").firstAnswer { url in
            if url.scheme == "https" { try await Task.sleep(for: .seconds(30)) }
            return url.scheme ?? ""
        }
        #expect(found.address == ServerAddress(scheme: .http, host: "nas.local"))
        #expect(found.answer == "http")
        #expect(clock.now - started < ServerAddress.httpsGrace + .seconds(2))
    }

    @Test func takesHTTPAtOnceWhenHTTPSFails() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let found = try await ServerAddress(host: "nas.local").firstAnswer { url in
            guard url.scheme == "http" else { throw URLError(.secureConnectionFailed) }
            return "Jellyfin"
        }
        #expect(found.address == ServerAddress(scheme: .http, host: "nas.local"))
        #expect(clock.now - started < ServerAddress.httpsGrace)
    }

    @Test func givesUpOnWhatTakesTooLong() async {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: URLError(.timedOut)) {
            try await withTimeLimit(.milliseconds(200)) {
                try await Task.sleep(for: .seconds(60))
            }
        }
        #expect(clock.now - started < .seconds(5))
    }
}

struct SignOutTests {
    private func signedIn(endingSessionWith endSession: @escaping @Sendable (JellyfinClient) async throws -> Void) throws
        -> (AccountStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "SignOutTests-\(UUID().uuidString)"))
        let account = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "server-\(UUID().uuidString)",
                                           serverName: "Home", userId: "u", userName: "alex")
        defaults.set(try JSONEncoder().encode(account), forKey: "account")
        let accounts = AccountStore(defaults: defaults, tokens: MemoryTokens([account.tokenKey: "token"]).store, endSession: endSession)
        #expect(accounts.account == account)
        return (accounts, defaults)
    }

    @Test func signsOutHereBeforeTheServerIsTold() async throws {
        let (told, telling) = AsyncStream.makeStream(of: String?.self)
        let (accounts, defaults) = try signedIn { client in
            telling.yield(client.token)
            // A server out of reach: the request never comes back.
            try await Task.sleep(for: .seconds(3600))
        }
        accounts.signOut()
        #expect(accounts.account == nil)
        #expect(accounts.client == nil)
        #expect(defaults.data(forKey: "account") == nil)
        // The server is told afterwards, with the sign-in that ended.
        var tokens = told.makeAsyncIterator()
        #expect(await tokens.next() == "token")
    }

    @Test func tellsTheServerOnceWhatNeedsTheSignInThereIsDone() async throws {
        let (steps, step) = AsyncStream.makeStream(of: String.self)
        let (accounts, _) = try signedIn { _ in step.yield("signed out on the server") }
        accounts.signOut { step.yield("transcodes deleted") }
        #expect(accounts.account == nil)
        var order = steps.makeAsyncIterator()
        #expect(await order.next() == "transcodes deleted")
        #expect(await order.next() == "signed out on the server")
    }

    @Test func remembersTheServersNameForTheNextSignIn() throws {
        let defaults = try #require(UserDefaults(suiteName: "SignOutTests-\(UUID().uuidString)"))
        defaults.set("Home", forKey: "lastServerName")
        #expect(AccountStore(defaults: defaults).lastServerName == "Home")
    }
}

/// Tokens kept in memory, under the names the Keychain keeps them by.
private nonisolated final class MemoryTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String]

    init(_ tokens: [String: String] = [:]) {
        self.tokens = tokens
    }

    subscript(key: String) -> String? { lock.withLock { tokens[key] } }

    var store: AccountStore.TokenStore {
        AccountStore.TokenStore(
            read: { key in self[key] },
            write: { token, key in self.lock.withLock { self.tokens[key] = token } },
            delete: { key in self.lock.withLock { self.tokens[key] = nil } }
        )
    }
}

private enum Kept {
    static let alex = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "home", serverName: "Home",
                                           userId: "u1", userName: "Alex")
    static let sam = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "home", serverName: "Home",
                                          userId: "u2", userName: "Sam")
    static let work = AccountStore.Account(serverURL: URL(string: "https://jf.example.com")!, serverId: "work", serverName: "Work",
                                           userId: "u1", userName: "Alex")

    /// Defaults with the sign-in in use and, unless nil, the list of those kept.
    static func defaults(inUse: AccountStore.Account?, kept: [AccountStore.Account]?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "KeptSignInTests-\(UUID().uuidString)"))
        if let inUse { defaults.set(try JSONEncoder().encode(inUse), forKey: "account") }
        if let kept { defaults.set(try JSONEncoder().encode(kept), forKey: "accounts") }
        return defaults
    }
}

struct KeptSignInTests {
    @Test func tokensAreKeptByServerAndUser() {
        #expect(Kept.alex.tokenKey == "home/u1")
        #expect(Kept.sam.tokenKey != Kept.alex.tokenKey)
        #expect(Kept.work.tokenKey != Kept.alex.tokenKey)
        // The same person on the same server, wherever it is and whatever it's called now.
        var moved = Kept.alex
        moved.serverURL = URL(string: "https://home.example.com")!
        moved.serverName = "Renamed"
        #expect(moved.isSame(as: Kept.alex))
        #expect(!Kept.sam.isSame(as: Kept.alex))
        #expect(!Kept.work.isSame(as: Kept.alex))
        #expect(!Kept.alex.isSame(as: nil))
    }

    @Test func keepsEverySignInAndUsesTheOneInUseWithItsOwnToken() throws {
        let tokens = MemoryTokens([Kept.alex.tokenKey: "alex", Kept.sam.tokenKey: "sam"])
        let accounts = AccountStore(defaults: try Kept.defaults(inUse: Kept.sam, kept: [Kept.alex, Kept.sam]), tokens: tokens.store)
        #expect(accounts.account == Kept.sam)
        #expect(accounts.client?.token == "sam")
        #expect(accounts.saved == [Kept.alex, Kept.sam])
        #expect(accounts.others == [Kept.alex])
    }

    @Test func aDeviceThatKeptOneSignInKeepsItWithItsTokenUnderItsOwnName() throws {
        let tokens = MemoryTokens(["home": "alex"])
        let accounts = AccountStore(defaults: try Kept.defaults(inUse: Kept.alex, kept: nil), tokens: tokens.store)
        #expect(accounts.account == Kept.alex)
        #expect(accounts.client?.token == "alex")
        #expect(accounts.saved == [Kept.alex])
        #expect(accounts.others.isEmpty)
        #expect(tokens[Kept.alex.tokenKey] == "alex")
        #expect(tokens["home"] == nil)
    }

    @Test func switchesToAKeptSignInWithItsOwnToken() throws {
        let defaults = try Kept.defaults(inUse: Kept.alex, kept: [Kept.alex, Kept.work])
        let tokens = MemoryTokens([Kept.alex.tokenKey: "alex", Kept.work.tokenKey: "work"])
        let accounts = AccountStore(defaults: defaults, tokens: tokens.store)
        try accounts.switchTo(Kept.work)
        #expect(accounts.account == Kept.work)
        #expect(accounts.client?.token == "work")
        #expect(accounts.client?.serverURL == Kept.work.serverURL)
        #expect(accounts.others == [Kept.alex])
        #expect(accounts.lastServerName == "Work")
        // And it's the one in use the next time the app opens.
        #expect(AccountStore(defaults: defaults, tokens: tokens.store).account == Kept.work)
    }

    @Test func aKeptSignInWhoseTokenIsGoneIsntKeptAnyMore() throws {
        let tokens = MemoryTokens([Kept.alex.tokenKey: "alex"])
        let accounts = AccountStore(defaults: try Kept.defaults(inUse: Kept.alex, kept: [Kept.alex, Kept.sam]), tokens: tokens.store)
        #expect(throws: AccountError.tokenMissing(Kept.sam)) { try accounts.switchTo(Kept.sam) }
        #expect(accounts.account == Kept.alex)
        #expect(accounts.saved == [Kept.alex])
        #expect(throws: AccountError.notKept(Kept.sam)) { try accounts.switchTo(Kept.sam) }
    }

    @Test func signingOutOfAnotherKeepsTheOneInUse() async throws {
        let (told, telling) = AsyncStream.makeStream(of: String?.self)
        let tokens = MemoryTokens([Kept.alex.tokenKey: "alex", Kept.sam.tokenKey: "sam"])
        let accounts = AccountStore(defaults: try Kept.defaults(inUse: Kept.alex, kept: [Kept.alex, Kept.sam]), tokens: tokens.store) {
            _ = telling.yield($0.token)
        }
        accounts.signOut(of: Kept.sam)
        #expect(accounts.account == Kept.alex)
        #expect(accounts.client?.token == "alex")
        #expect(accounts.saved == [Kept.alex])
        #expect(tokens[Kept.sam.tokenKey] == nil)
        #expect(tokens[Kept.alex.tokenKey] == "alex")
        // The server hears from the sign-in that ended.
        var heard = told.makeAsyncIterator()
        #expect(await heard.next() == "sam")
    }

    @Test func signingOutOfTheOneInUseLeavesNoneInUseAndKeepsTheOthers() throws {
        let defaults = try Kept.defaults(inUse: Kept.alex, kept: [Kept.alex, Kept.sam])
        let tokens = MemoryTokens([Kept.alex.tokenKey: "alex", Kept.sam.tokenKey: "sam"])
        let accounts = AccountStore(defaults: defaults, tokens: tokens.store) { _ in }
        accounts.signOut()
        #expect(accounts.account == nil)
        #expect(accounts.client == nil)
        #expect(accounts.saved == [Kept.sam])
        #expect(tokens[Kept.alex.tokenKey] == nil)
        #expect(tokens[Kept.sam.tokenKey] == "sam")
        let reopened = AccountStore(defaults: defaults, tokens: tokens.store)
        #expect(reopened.account == nil)
        #expect(reopened.others == [Kept.sam])
    }

    @Test func readsThePeopleAServerLists() throws {
        let listed = #"[{"Name":"Alex","Id":"u1","PrimaryImageTag":"abc","HasPassword":false},{"Name":"Sam","Id":"u2"}]"#
        let users = try JSONDecoder().decode([PublicUser].self, from: Data(listed.utf8))
        #expect(users == [PublicUser(id: "u1", name: "Alex", primaryImageTag: "abc", hasPassword: false), PublicUser(id: "u2", name: "Sam")])
    }
}

struct DiscoveryTests {
    @Test func readsAServersAnswer() throws {
        let reply = #"{"Address":"http://192.168.1.10:8096","Id":"a1b2","Name":"Home","EndpointAddress":null}"#
        let server = try #require(DiscoveredServer(reply: Data(reply.utf8)))
        #expect(server == DiscoveredServer(id: "a1b2", name: "Home", address: URL(string: "http://192.168.1.10:8096")!))
    }

    @Test func keepsABasePathAndNamesAServerWithoutANameByItsHost() throws {
        let reply = #"{"Address":"https://jf.example.com/jellyfin/","Id":"a1b2","Name":" "}"#
        let server = try #require(DiscoveredServer(reply: Data(reply.utf8)))
        #expect(server.address == URL(string: "https://jf.example.com/jellyfin")!)
        #expect(server.name == "jf.example.com")
    }

    @Test func ignoresAnythingElse() {
        let replies = [
            "who is JellyfinServer?",
            "{}",
            #"{"Address":"http://nas.local:8096","Id":""}"#,
            #"{"Address":"ftp://nas.local","Id":"a1b2"}"#,
            #"{"Address":"nas.local:8096","Id":"a1b2"}"#,
            #"{"Id":"a1b2","Name":"Home"}"#,
        ]
        for reply in replies {
            #expect(DiscoveredServer(reply: Data(reply.utf8)) == nil, "\(reply)")
        }
    }

    @Test func listsEachServerOnceByName() {
        let discovery = ServerDiscovery()
        discovery.take(DiscoveredServer(id: "2", name: "work", address: URL(string: "https://jf.example.com")!))
        discovery.take(DiscoveredServer(id: "1", name: "Home", address: URL(string: "http://192.168.1.10:8096")!))
        // The same server answering from another of its addresses.
        discovery.take(DiscoveredServer(id: "1", name: "Home", address: URL(string: "http://192.168.1.11:8096")!))
        #expect(discovery.servers.map(\.id) == ["1", "2"])
        #expect(discovery.servers.first?.address.host() == "192.168.1.11")
    }
}
