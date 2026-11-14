import Network
import XCTest

/// Signs in as someone would, the server first for someone new and the account first for anyone
/// who has signed in before, against the local test server `VinnyfinUITests` describes: a user
/// "viewer" without a password. Another server and
/// user without a password come from `VINNYFIN_TEST_SERVER` and `VINNYFIN_TEST_USER` (pass
/// `TEST_RUNNER_VINNYFIN_TEST_SERVER` and `TEST_RUNNER_VINNYFIN_TEST_USER` to xcodebuild).
final class SignInUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var server: String {
        ProcessInfo.processInfo.environment["VINNYFIN_TEST_SERVER"] ?? "http://localhost:8096"
    }

    private var username: String {
        ProcessInfo.processInfo.environment["VINNYFIN_TEST_USER"] ?? "viewer"
    }

    private func requireServer() async throws {
        let info = try XCTUnwrap(URL(string: server + "/System/Info/Public"))
        let answered = (try? await URLSession.shared.data(from: info)) != nil
        try XCTSkipUnless(answered, "No Jellyfin test server answers at \(server)")
    }

    /// Signs in from wherever the app starts, then signs out and in to the test server, changing
    /// the server the sign-in screen picks when the last sign-in was to another. Signed out again,
    /// the screen starts from that sign-in, its user and its server picked, which sign straight in.
    @MainActor
    func testSignsInAgainFromTheLastSignIn() async throws {
        try await requireServer()
        let app = XCUIApplication()
        #if os(visionOS)
        app.launchArguments = try signInArguments(server: server, username: username)
        #endif
        app.launch()
        signIn(app)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in never finished")
        signOut(app)
        signIn(app)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in after signing out never finished")

        signOut(app)
        #if !os(tvOS)
        tap(app.buttons["welcome.connect"])
        #endif
        let picked = app.buttons["login.changeServer"]
        XCTAssertTrue(picked.waitForExistence(timeout: uiTimeout), "The sign-in screen didn't pick the server signed in to last")
        XCTAssertTrue(isAddress(picked.value as? String, of: server), "The sign-in screen picked \(String(describing: picked.value))")
        XCTAssertEqual(app.textFields["login.username"].value as? String, username)
        #if !os(tvOS)
        // Closed, for the sign-in to open it as it does from the start.
        tap(app.buttons["Cancel"])
        XCTAssertTrue(picked.waitForNonExistence(timeout: uiTimeout), "Cancel didn't close the sign-in screen")
        #endif
        signIn(app)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in again never finished")
    }

    #if os(iOS) || os(macOS)
    /// A server that doesn't answer keeps the server step, with its error and the cursor in the
    /// host. Putting the address right while a sign-in waits on one that never answers takes that
    /// sign-in back: Sign In works again, the server is found where the address says, and nothing
    /// of the sign-in taken back shows. Back goes to the account step with the server picked
    /// before, which signs in.
    @MainActor
    func testAServerThatDoesntAnswerKeepsTheServerStep() async throws {
        try await requireServer()
        let app = XCUIApplication()
        app.launch()
        signIn(app)
        signOut(app)
        tap(app.buttons["welcome.connect"])

        let picked = app.buttons["login.changeServer"]
        tap(picked)
        // Change puts the cursor in the address, and Return connects. Nothing listens on port 9.
        let host = app.textFields["login.host"]
        enterAddress("127.0.0.1:9", into: host)
        XCTAssertTrue(app.descendants(matching: .any)["login.error"].waitForExistence(timeout: uiTimeout),
                      "The server step never said the server doesn't answer")
        XCTAssertTrue(app.buttons["login.connect"].exists, "The sign-in left the server step")
        XCTAssertTrue(waitForKeyboardFocus(host), "The cursor didn't go back to the address")
        XCTAssertEqual(host.value as? String, "127.0.0.1:9")
        keep("Server step with its error", in: app)

        let silent = try SilentServer()
        defer { silent.stop() }
        let silentPort = try await silent.port()
        enterAddress("127.0.0.1:\(silentPort)", into: host)
        let connect = app.buttons["login.connect"]
        XCTAssertTrue(connect.wait(for: \.isEnabled, toEqual: false, timeout: uiTimeout), "Sign In never started")
        // Typed without Return, which would connect.
        host.tap()
        host.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + server)
        XCTAssertTrue(connect.wait(for: \.isEnabled, toEqual: true, timeout: 5), "Sign In stayed taken by the sign-in to the old address")
        let found = app.descendants(matching: .any)["login.found"]
        XCTAssertTrue(found.waitForExistence(timeout: uiTimeout), "The server wasn't found at the corrected address")
        // Past the time the sign-in taken back would have given up in.
        try await Task.sleep(for: .seconds(8))
        XCTAssertTrue(found.exists, "The server found at the corrected address stopped showing")
        XCTAssertFalse(app.descendants(matching: .any)["login.error"].exists, "The sign-in taken back showed its error")
        XCTAssertTrue(connect.isEnabled, "Sign In didn't stay available")
        keep("Corrected address found", in: app)

        // Back, at the leading end of the bar.
        #if os(macOS)
        tap(app.toolbars.buttons.element(boundBy: 0))
        #else
        tap(app.navigationBars.buttons.element(boundBy: 0))
        #endif
        XCTAssertTrue(picked.waitForExistence(timeout: uiTimeout), "Back didn't go to the account step")
        XCTAssertTrue(isAddress(picked.value as? String, of: server), "Back picked \(String(describing: picked.value))")
        XCTAssertFalse(app.descendants(matching: .any)["login.error"].exists, "The server step's error stayed")
        // Return on the password signs in to the server picked.
        let password = app.secureTextFields["login.password"]
        password.tap()
        type("\n", into: password)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in from the account step never finished")
    }

    /// An address copied from Jellyfin's web app in a browser, "…/web/#/home.html", signs in to
    /// the server it's the web app of.
    @MainActor
    func testSignsInWithAnAddressCopiedFromABrowser() async throws {
        try await requireServer()
        let app = XCUIApplication()
        app.launch()
        signIn(app)
        signOut(app)
        tap(app.buttons["welcome.connect"])
        tap(app.buttons["login.changeServer"])
        enterAddress(server + "/web/#/home.html", into: app.textFields["login.host"])
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in with the browser's address never finished")
    }

    @MainActor
    private func keep(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    #if !os(tvOS)
    /// Quick Connect from the account step goes straight to the code of the server picked, and
    /// signs in once someone signed in approves it.
    @MainActor
    func testQuickConnectSignsInOnceTheCodeIsApproved() async throws {
        try await requireServer()
        let app = XCUIApplication()
        #if os(visionOS)
        app.launchArguments = try signInArguments(server: server, username: username)
        #endif
        app.launch()
        // Signed in to the test server last, whichever server an earlier test left it on: the code
        // comes from the server the sign-in screen picks, and the test user approves it there.
        if tabs(app).waitForExistence(timeout: 5) { signOut(app) }
        signIn(app)
        signOut(app)
        tap(app.buttons["welcome.connect"])
        XCTAssertTrue(app.buttons["login.changeServer"].waitForExistence(timeout: uiTimeout),
                      "The sign-in screen didn't pick the server signed in to last")

        tap(app.buttons["login.quickConnect"])
        let code = app.staticTexts["login.quickConnectCode"]
        XCTAssertTrue(code.waitForExistence(timeout: uiTimeout), "No Quick Connect code came up")
        try await approve(code.label)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Approving the code didn't sign in")
    }

    private struct Authentication: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "AccessToken" }
    }

    /// Approves a Quick Connect code as the test user, as Jellyfin on a device signed in would.
    private func approve(_ code: String) async throws {
        let client = #"MediaBrowser Client="vinnyfin UI tests", Device="Test runner", DeviceId="vinnyfin-ui-tests", Version="1""#
        var signIn = URLRequest(url: try XCTUnwrap(URL(string: server + "/Users/AuthenticateByName")))
        signIn.httpMethod = "POST"
        signIn.setValue(client, forHTTPHeaderField: "Authorization")
        signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signIn.httpBody = try JSONEncoder().encode(["Username": username, "Pw": ""])
        let token = try JSONDecoder().decode(Authentication.self, from: try await URLSession.shared.data(for: signIn).0).accessToken
        var approval = URLRequest(url: try XCTUnwrap(URL(string: server + "/QuickConnect/Authorize?code=" + code)))
        approval.httpMethod = "POST"
        approval.setValue(client + #", Token="\#(token)""#, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: approval)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "The server didn't approve the code")
    }
    #endif

    #if os(iOS)
    /// Signing in with a password asks whether to save it in iCloud, over the library once the
    /// sign-in screen has gone, and Not Now leaves the app signed in. The password is the demo
    /// account's, on the demo server, which someone new reaches through the username first.
    @MainActor
    func testAsksWhetherToSaveThePasswordSignedInWith() async throws {
        let info = try XCTUnwrap(URL(string: "https://jftest.vinnysaj.net/System/Info/Public"))
        let answered = (try? await URLSession.shared.data(from: info)) != nil
        try XCTSkipUnless(answered, "The demo server doesn't answer")
        let app = XCUIApplication()
        app.launch()
        if tabs(app).waitForExistence(timeout: 5) { signOut(app) }
        tap(app.buttons["welcome.connect"])
        let usernameField = app.textFields["login.username"]
        let usernameFirst = app.buttons["login.usernameFirst"]
        XCTAssertNotNil(firstToAppear(usernameField, usernameFirst), "The sign-in form never opened")
        if usernameFirst.exists { tap(usernameFirst) }
        tap(usernameField)
        usernameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "apple\n")
        type("apple\n", into: app.secureTextFields["login.password"])

        let alert = app.alerts["Save Password to iCloud?"]
        XCTAssertTrue(alert.waitForExistence(timeout: uiTimeout), "Signing in with a password didn't ask whether to save it")
        alert.buttons["Not Now"].tap()
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in never finished")
        XCTAssertFalse(alert.exists, "The question stayed after it was answered")
    }
    #endif

    @MainActor
    private func signIn(_ app: XCUIApplication) {
        #if os(visionOS)
        signInIfNeeded(app)
        #else
        signInIfNeeded(app, server: server, username: username)
        #endif
    }

    /// The Movies tab, which is there once signed in.
    @MainActor
    private func tabs(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Movies'")).firstMatch
    }
}

#if os(iOS) || os(macOS)
/// A server on this Mac that takes connections and never answers, as one out of reach behind a
/// router that lets the connection through does. The simulator's apps share the Mac's network.
@MainActor
private final class SilentServer {
    private let listener: NWListener
    /// Held open, so they hang rather than close.
    private var connections: [NWConnection] = []

    struct NotListening: Error {}

    init() throws {
        listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                self?.connections.append(connection)
            }
        }
        listener.start(queue: .main)
    }

    /// The port it listens on, once it does.
    func port() async throws -> UInt16 {
        for _ in 0..<50 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NotListening()
    }

    func stop() {
        connections.forEach { $0.cancel() }
        listener.cancel()
    }
}
#endif
