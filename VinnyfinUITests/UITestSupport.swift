import XCTest

/// How long a UI test waits on the app or the server before failing.
let uiTimeout: TimeInterval = 30

#if os(visionOS)
/// Asks for a screenshot named `name` and waits for it. On visionOS a UI test's own
/// screenshots come back empty, so `simctl io screenshot` on the Mac takes it: the test
/// leaves `<name>.request` in `VINNYFIN_SHOTS` and a watcher there answers with `<name>.png`.
/// Without the folder there's nothing to take it, and the step goes on.
func requestScreenshot(_ name: String) async throws {
    guard let folder = ProcessInfo.processInfo.environment["VINNYFIN_SHOTS"] else { return }
    try await Task.sleep(for: .seconds(1))
    let request = URL(filePath: folder).appending(path: name + ".request")
    try Data().write(to: request)
    let deadline = Date.now.addingTimeInterval(15)
    while FileManager.default.fileExists(atPath: request.path), Date.now < deadline {
        try await Task.sleep(for: .seconds(0.3))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "No screenshot was taken for \(name)")
}
#endif

extension XCTestCase {
    #if os(tvOS)
    /// Signs in to `server` as `username`, a user without a password, with the remote: down
    /// through the form, typing into each field the keyboard opens for. Someone new gives the
    /// server first, then the account; anyone who has signed in before, the account first, then
    /// the server, unless the last sign-in picked it.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication, server: String, username: String) {
        let connect = app.buttons["welcome.connect"]
        if connect.waitForExistence(timeout: 5) {
            focus(connect, in: app)
            XCUIRemote.shared.press(.select)
        }
        let usernameField = app.textFields["login.username"]
        let host = app.textFields["login.host"]
        guard let first = firstToAppear(usernameField, host) else { return }
        if first == .second {
            self.connect(to: server, from: host, in: app)
            XCTAssertTrue(usernameField.waitForExistence(timeout: uiTimeout), "The server step never led to the account step")
        }
        enter(username, into: usernameField, in: app)
        let change = app.buttons["login.changeServer"]
        let changing = change.exists && !isAddress(change.value as? String, of: server)
        if changing {
            focus(change, in: app)
        } else {
            let submit = app.buttons["login.submit"]
            XCTAssertTrue(submit.wait(for: \.isEnabled, toEqual: true, timeout: uiTimeout), "Sign In never became enabled")
            focus(submit, in: app)
        }
        XCUIRemote.shared.press(.select)
        guard waitForServerStep(host, orSignInPast: usernameField) else { return }
        self.connect(to: server, from: host, in: app)
    }

    /// Replaces the server step's address with `server`, protocol, port, path and all, and
    /// connects to it.
    @MainActor
    private func connect(to server: String, from host: XCUIElement, in app: XCUIApplication) {
        enter(server, into: host, in: app)
        focus(app.buttons["login.connect"], in: app)
        XCUIRemote.shared.press(.select)
    }

    /// Moves focus each way in turn, down and then back up past the end unless told otherwise,
    /// until `element` has it: a button in a form or the sidebar takes it as its row, a cell.
    @MainActor
    func focus(_ element: XCUIElement, in app: XCUIApplication, moving directions: [XCUIRemote.Button] = [.down, .up],
               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout), "\(element) never appeared", file: file, line: line)
        // Its row is found by its identifier, so an element without one has to take focus itself.
        let identifier = element.identifier
        let row = app.cells.containing(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        let isFocused = { element.hasFocus || !identifier.isEmpty && row.exists && row.hasFocus }
        for direction in directions {
            for _ in 0..<12 {
                if isFocused() { return }
                XCUIRemote.shared.press(direction)
            }
        }
        XCTAssertTrue(isFocused(), "\(element) never took focus", file: file, line: line)
    }

    /// Opens the keyboard for `field`, replaces what's in it with `text`, and goes back to the form.
    @MainActor
    private func enter(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        focus(field, in: app)
        XCUIRemote.shared.press(.select)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: uiTimeout), "The keyboard never opened for \(field)")
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + text)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: uiTimeout), "The keyboard never closed")
    }
    #elseif os(visionOS)
    /// Launch arguments that fill in the sign-in form with `server` and `username`, a user without
    /// a password. Text typed by a UI test doesn't reach visionOS's text fields, so the form starts
    /// from the defaults the last sign-in left, which arguments set: the server as an archived
    /// URL, given as property list data.
    func signInArguments(server: String, username: String) throws -> [String] {
        let url = try XCTUnwrap(NSURL(string: server), "\(server) isn't an address")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: url, requiringSecureCoding: true)
        return ["-lastServer", "<\(archived.map { String(format: "%02x", $0) }.joined())>", "-lastUserName", username]
    }

    /// Signs in with the form as it starts, from the last sign-in or `signInArguments`: its server
    /// picked and its user filled in, so Sign In signs straight in. The build must be signed, even
    /// ad hoc, for the Keychain to take the sign-in.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication) {
        let connect = app.buttons["welcome.connect"]
        guard connect.waitForExistence(timeout: 5) else { return }
        connect.tap()
        XCTAssertTrue(app.textFields["login.username"].waitForExistence(timeout: uiTimeout), "The sign-in form never opened")
        XCTAssertTrue(app.buttons["login.changeServer"].exists, "The sign-in form didn't start from the last sign-in's server")
        tap(app.buttons["login.submit"])
    }
    #else
    /// Signs in to `server` as `username`, a user without a password: typing a password would
    /// raise the system's Save Password sheet. Someone new gives the server first, then the
    /// account; anyone who has signed in before, the account first, then the server, unless the
    /// last sign-in picked it.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication, server: String, username: String) {
        let connect = app.buttons["welcome.connect"]
        if connect.waitForExistence(timeout: 5) { connect.tap() }
        let usernameField = app.textFields["login.username"]
        let host = app.textFields["login.host"]
        guard let first = firstToAppear(usernameField, host) else { return }
        if first == .second {
            host.tap()
            enterAddress(server, into: host)
            // Return walks the account step's fields, username then password, then signs in.
            type(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + username + "\n", into: usernameField)
            type("\n", into: app.secureTextFields["login.password"])
            return
        }
        // The form starts from the last sign-in's user and server. Return walks the fields:
        // username, password, then signs in to the server picked, or asks for one.
        usernameField.tap()
        usernameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + username + "\n")
        let change = app.buttons["login.changeServer"]
        let changing = change.exists && !isAddress(change.value as? String, of: server)
        if changing {
            tap(change)
        } else {
            type("\n", into: app.secureTextFields["login.password"])
        }
        guard waitForServerStep(host, orSignInPast: usernameField) else { return }
        enterAddress(server, into: host)
    }

    /// Replaces the server step's address, which has the cursor, with `server`, protocol, port,
    /// path and all, and Return connects to it. The tap is past the end of the text, so the
    /// deletes before the cursor take all of it: one in the middle of a long address, such as
    /// the demo server's, leaves the rest after what's typed.
    @MainActor
    func enterAddress(_ server: String, into host: XCUIElement) {
        XCTAssertTrue(waitForKeyboardFocus(host), "The address field never took focus")
        host.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        host.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + server + "\n")
    }

    /// Types once `field` has the keyboard focus that Return moved to it.
    @MainActor
    func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(waitForKeyboardFocus(field), "\(field) never took focus")
        field.typeText(text)
    }

    /// Whether `element` takes the keyboard focus in time.
    @MainActor
    func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter.wait(for: [focused], timeout: uiTimeout) == .completed
    }
    #endif

    /// Signs out in Settings: on its Account page, in a sheet from Home on iPhone and in a tab on
    /// iPad, Vision Pro and Apple TV, and in the General pane of the Mac's Settings window.
    @MainActor
    func signOut(_ app: XCUIApplication) {
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign Out' AND identifier != 'settings.signOut'")).firstMatch
        #if os(tvOS)
        // Left into the sidebar, no further: a press left there closes it. Focus may still be on
        // its way there, as it is at launch.
        let sidebar = app.collectionViews["Sidebar"]
        let focusedRow = sidebar.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<12 where !focusedRow.waitForExistence(timeout: 1) { XCUIRemote.shared.press(.left) }
        focus(sidebar.buttons["Settings"], in: app)
        XCUIRemote.shared.press(.select)
        focus(app.buttons["settings.account"], in: app, moving: [.right, .up])
        XCUIRemote.shared.press(.select)
        focus(app.buttons["settings.signOut"], in: app, moving: [.down])
        XCUIRemote.shared.press(.select)
        // The dialog's buttons are side by side, Cancel first.
        focus(confirm, in: app, moving: [.right, .left])
        XCUIRemote.shared.press(.select)
        #elseif os(macOS)
        app.typeKey(",", modifierFlags: .command)
        tap(app.buttons["settings.signOut"])
        tap(confirm)
        app.typeKey("w", modifierFlags: .command)
        #else
        openSettings(app)
        tap(app.buttons["settings.account"])
        // Down the page to it, past the screen's bottom at the largest text sizes.
        let signOut = app.buttons["settings.signOut"]
        for _ in 0..<8 where !signOut.waitForExistence(timeout: 2) { app.swipeUp() }
        tap(signOut)
        tap(confirm)
        #endif
    }

    #if os(iOS) || os(visionOS)
    /// Opens Settings: on iPhone a sheet from the account menu, Home's avatar, whose items XCUITest
    /// knows by their labels; on iPad and Vision Pro a tab of its own. Whether it's a sheet, which
    /// Done closes.
    @MainActor @discardableResult
    func openSettings(_ app: XCUIApplication) -> Bool {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            tap(app.buttons["home.settings"])
            tap(app.buttons.matching(NSPredicate(format: "identifier == 'home.openSettings' OR label == 'Settings'")).firstMatch)
            return true
        }
        #endif
        tap(tab("Settings", in: app))
        return false
    }
    #endif

    #if !os(visionOS)
    /// Which of two elements appears first.
    enum Appeared { case first, second }

    /// Which of two elements appears first, within a few seconds; nil for neither.
    @MainActor
    func firstToAppear(_ first: XCUIElement, _ second: XCUIElement) -> Appeared? {
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            if first.exists { return .first }
            if second.exists { return .second }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        } while Date.now < deadline
        return nil
    }

    /// Waits for the sign-in screen to ask for the server's address, or to sign in to the server
    /// it picked, which takes it and the account step away. Whether it asked.
    @MainActor
    private func waitForServerStep(_ host: XCUIElement, orSignInPast usernameField: XCUIElement) -> Bool {
        let deadline = Date.now.addingTimeInterval(uiTimeout)
        while !host.waitForExistence(timeout: 1), usernameField.exists, Date.now < deadline {}
        return host.exists
    }
    #endif

    /// Whether `address`, a server's as the sign-in screen gives it, is `server`'s.
    func isAddress(_ address: String?, of server: String) -> Bool {
        func normalized(_ text: String) -> String { text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return address.map(normalized) == normalized(server)
    }

    #if !os(tvOS)
    /// Taps once the element is there and enabled; buttons wait on loading, and a tap before
    /// then does nothing.
    @MainActor
    func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout), "\(element) never appeared", file: file, line: line)
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: uiTimeout), "\(element) never became enabled", file: file, line: line)
        element.tap()
    }

    /// A tab: a button in the tab bar, a row in iPad's sidebar, or a button in the bar down the
    /// side of iPhone Duo's outer display, which isn't a tab bar to XCUITest. A tab reads its
    /// badge's count after its name. Not the back button to the tab's first screen, which can
    /// have the same name.
    @MainActor
    func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let named = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ", ")
        let places = [app.tabBars.buttons.matching(named).firstMatch, app.cells.matching(named).firstMatch,
                      app.buttons.matching(named).matching(NSPredicate(format: "identifier != 'BackButton'")).firstMatch]
        let deadline = Date.now.addingTimeInterval(uiTimeout)
        while Date.now < deadline {
            if let tab = places.first(where: \.exists) { return tab }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        return places[0]
    }
    #endif
}

/// The position and length in seconds that the player's timeline reads out, as VoiceOver says
/// them: "4 minutes, 9 seconds of 1 hour, 30 minutes", with the chapter after when it has one.
func timelinePosition(_ value: String?) -> (time: Double, duration: Double)? {
    // The first " of " only: a chapter's name may have its own.
    guard let value, let separator = value.range(of: " of ") else { return nil }
    let sides = [value[..<separator.lowerBound], value[separator.upperBound...]]
    func seconds(_ text: Substring) -> Double {
        let units = ["hour": 3600.0, "minute": 60.0, "second": 1.0]
        let words = text.split { $0 == " " || $0 == "," }
        return zip(words, words.dropFirst()).reduce(0) { total, pair in
            guard let count = Double(pair.0), let unit = units.first(where: { pair.1.hasPrefix($0.key) })?.value else { return total }
            return total + count * unit
        }
    }
    let duration = seconds(sides[1])
    guard duration > 0 else { return nil }
    return (seconds(sides[0]), duration)
}

/// A position in seconds as the timeline shows it on screen: "4:09", "1:04:09".
func clockText(_ seconds: Double) -> String {
    let total = Int(seconds)
    let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}
