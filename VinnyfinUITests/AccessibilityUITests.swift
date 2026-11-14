import XCTest

/// Walks the app's common tasks running Apple's accessibility audit on each screen (what
/// Accessibility Inspector checks) and keeping a screenshot of it to look over.
///
/// It runs on the device as set up, so each text size, appearance and contrast is a run of its
/// own, set beforehand with `xcrun simctl ui <device> content_size <size>`, `appearance dark` or
/// `increase_contrast enabled`; a launch argument pinning the text size would keep the app from
/// following the size the audit tries. Contrast, Dynamic Type and clipped text are the
/// screenshots' to show, not the audit's: see `auditTypes`.
///
/// Signed out: the welcome screen and the sign-in form. Signed in to `VINNYFIN_TEST_SERVER`
/// (default http://localhost:8096) as `VINNYFIN_TEST_USER` (default "viewer"), a user without a
/// password: Home, Settings, Downloads, Shows and a show's page, Movies, a film's page and its
/// player, and Search, the first title of each library standing in for any. Skipped without it.
final class AccessibilityUITests: XCTestCase {
    /// All but contrast, Dynamic Type and clipped text, which the audit gets wrong on these screens:
    /// it measures contrast through Liquid Glass and under the floating tab bar, finds text in
    /// sheets and lazy grids that grows with the text size unsupported, and calls text clipped
    /// that wraps at the larger sizes. The Mac's audit has no Dynamic Type or clipped text checks.
    #if os(macOS)
    private static let auditTypes = XCUIAccessibilityAuditType.all.subtracting(.contrast)
    #else
    private static let auditTypes = XCUIAccessibilityAuditType.all.subtracting([.contrast, .dynamicType, .textClipped])
    #endif

    override func setUp() {
        // Every issue on every screen, not only the first.
        continueAfterFailure = true
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

    @MainActor
    func testSignedOut() async throws {
        let app = try launch()
        // Apple TV has no welcome screen: it starts at the sign-in form.
        let connect = app.buttons["welcome.connect"]
        let username = app.textFields["login.username"]
        if !connect.waitForExistence(timeout: 10), !username.exists {
            signOut(app)
        }
        #if !os(tvOS)
        XCTAssertTrue(connect.waitForExistence(timeout: uiTimeout), "Signing out never finished")
        try await check(app, "welcome")
        open(connect, in: app)
        #endif
        XCTAssertTrue(username.waitForExistence(timeout: uiTimeout), "The sign-in form never opened")
        try await check(app, "sign-in")
    }

    @MainActor
    func testCommonTasks() async throws {
        try await requireServer()
        let app = try launchSignedIn()
        try await check(app, "home")

        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["settings.signOut"].waitForExistence(timeout: uiTimeout), "Settings never opened")
        try await check(app, "settings")
        app.typeKey("w", modifierFlags: .command)
        #elseif os(tvOS)
        openTab("Settings", in: app)
        XCTAssertTrue(app.buttons["settings.account"].waitForExistence(timeout: uiTimeout), "Settings never opened")
        try await check(app, "settings")
        #else
        if openSettings(app) {
            // Done, not a setting: at the largest text sizes the settings start below the screen.
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: uiTimeout), "Settings never opened")
            try await check(app, "settings", isSheet: true)
            tap(done)
        } else {
            XCTAssertTrue(app.buttons["settings.account"].waitForExistence(timeout: uiTimeout), "Settings never opened")
            try await check(app, "settings")
        }
        #endif

        #if !os(tvOS)
        openTab("Downloads", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["downloads.openFile"].waitForExistence(timeout: uiTimeout), "Downloads never opened")
        try await check(app, "downloads")
        #endif

        openTab("Shows", in: app)
        XCTAssertTrue(poster(in: app).waitForExistence(timeout: uiTimeout), "Shows never listed a show")
        try await check(app, "shows")
        open(poster(in: app), in: app)
        XCTAssertTrue(app.buttons["series.play"].waitForExistence(timeout: uiTimeout), "The show's page never opened")
        try await check(app, "show")
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #endif

        openTab("Movies", in: app)
        XCTAssertTrue(poster(in: app).waitForExistence(timeout: uiTimeout), "Movies never listed a film")
        try await check(app, "movies")
        open(poster(in: app), in: app)
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: uiTimeout), "The film's page never opened")
        try await check(app, "film")
        open(play, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["player.timeline"].waitForExistence(timeout: uiTimeout), "The player never opened")
        try await check(app, "player")
    }

    /// A search of its own: on iPad the search field takes the tab bar's place, leaving no tab to
    /// go on to.
    @MainActor
    func testSearch() async throws {
        try await requireServer()
        let app = try launchSignedIn()
        // A word of a title Home shows, for results.
        let searchTerm = String(title(in: app).label.split(separator: " ").first ?? "a")
        openTab("Search", in: app)
        #if os(iOS) || os(macOS)
        // On Apple TV and Vision Pro, a UI test's typing doesn't reach the field, so there it's
        // the screen before a search.
        let field = app.searchFields.firstMatch
        tap(field)
        field.typeText(searchTerm + "\n")
        XCTAssertTrue(poster(in: app).waitForExistence(timeout: uiTimeout), "Searching for \(searchTerm) found nothing")
        #endif
        try await check(app, "search")
    }

    // MARK: Steps

    /// Launched and signed in, with Home showing its titles.
    @MainActor
    private func launchSignedIn() throws -> XCUIApplication {
        let app = try launch()
        #if os(visionOS)
        signInIfNeeded(app)
        #else
        signInIfNeeded(app, server: server, username: username)
        #endif
        XCTAssertTrue(title(in: app).waitForExistence(timeout: uiTimeout), "Home never showed a title")
        return app
    }

    /// The first title on Home.
    @MainActor
    private func title(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'poster.' OR identifier BEGINSWITH 'card.'")).firstMatch
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication()
        #if os(visionOS)
        app.launchArguments = try signInArguments(server: server, username: username)
        #elseif os(macOS)
        // A window of the default size, not wherever an earlier run left it.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        return app
    }

    /// The first title on screen.
    @MainActor
    private func poster(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'poster.'")).firstMatch
    }

    /// Opens `element`: a tap, or on Apple TV, focus moved to it and Select.
    @MainActor
    private func open(_ element: XCUIElement, in app: XCUIApplication) {
        #if os(tvOS)
        focus(element, in: app, moving: [.right, .down, .up])
        XCUIRemote.shared.press(.select)
        #else
        tap(element)
        #endif
    }

    @MainActor
    private func openTab(_ name: String, in app: XCUIApplication) {
        #if os(tvOS)
        // Left into the sidebar, which a press left in it closes; focus may still be on its way.
        let sidebar = app.collectionViews["Sidebar"]
        let focusedRow = sidebar.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<12 where !focusedRow.waitForExistence(timeout: 1) { XCUIRemote.shared.press(.left) }
        focus(sidebar.buttons[name], in: app)
        XCUIRemote.shared.press(.select)
        #else
        tap(tab(name, in: app))
        #endif
    }

    /// Audits the screen as it is, and keeps a screenshot of it, under `screen`. A sheet leaves the
    /// screen it covers in view, dimmed, whose text the audit finds VoiceOver can't reach, as it
    /// can't while the sheet is up; there it doesn't look for text out of VoiceOver's reach.
    @MainActor
    private func check(_ app: XCUIApplication, _ screen: String, isSheet: Bool = false) async throws {
        #if os(visionOS)
        try await requestScreenshot(screen)
        #else
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = screen
        shot.lifetime = .keepAlways
        add(shot)
        #endif
        try XCTContext.runActivity(named: "Audit \(screen)") { _ in
            let types = isSheet ? Self.auditTypes.subtracting(.elementDetection) : Self.auditTypes
            try app.performAccessibilityAudit(for: types) { issue in
                // A hit area is for what's tapped, not for text that's only read, as a truncated
                // title the audit takes for a control.
                if issue.auditType == .hitRegion, issue.element?.elementType == .staticText { return true }
                // Each issue with the screen and the element, which the audit's own failure leaves out.
                let element = issue.element.map { "\($0.elementType) \"\($0.label)\" [\($0.identifier)] at \($0.frame)" } ?? "the screen"
                XCTFail("\(screen): \(issue.compactDescription) on \(element). \(issue.detailedDescription)")
                return true
            }
        }
    }
}
