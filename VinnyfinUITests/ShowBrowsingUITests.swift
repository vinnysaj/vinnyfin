#if os(iOS) || os(tvOS)
import XCTest

/// Browses a show from one of its episodes against the showcase server `AppStore/screenshots.sh`
/// runs: from the show's page to an episode's, along the season's episodes there, and back to
/// the show by its name. Skipped without that server.
final class ShowBrowsingUITests: XCTestCase {
    private var server = ""

    override func setUp() async throws {
        continueAfterFailure = false
        let address = ProcessInfo.processInfo.environment["VINNYFIN_SCREENSHOT_SERVER"]
        try XCTSkipUnless(address != nil, "Needs the showcase server AppStore/screenshots.sh runs")
        server = address ?? ""
    }

    #if os(iOS)
    @MainActor
    func testAnEpisodesPageBrowsesItsShow() throws {
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")
        tap(tab("Shows", in: app))
        tap(app.buttons["poster.Port Ellery"])
        tap(app.buttons["episode.2.details"])

        let show = app.buttons["detail.eyebrow"]
        XCTAssertTrue(show.waitForExistence(timeout: uiTimeout), "The episode's page doesn't lead to its show")
        XCTAssertEqual(show.label, "Port Ellery")
        let second = app.buttons["seasonBrowser.episode.2"]
        XCTAssertTrue(second.waitForExistence(timeout: uiTimeout), "The episode's page doesn't list the season's episodes")
        XCTAssertTrue((second.value as? String)?.contains("viewing") == true, "The episode shown isn't marked")
        keep(app.screenshot(), named: "episode-page")

        // The one before the episode shown is in view beside it.
        let first = app.buttons["seasonBrowser.episode.1"]
        tap(first)
        let marked = NSPredicate(format: "value CONTAINS 'viewing'")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: marked, object: first)], timeout: uiTimeout) == .completed,
                      "Picking another episode didn't show it")
        keep(app.screenshot(), named: "another-episode")

        tap(show)
        XCTAssertTrue(app.buttons["episode.1"].waitForExistence(timeout: uiTimeout), "The show's name didn't lead to its page")
        keep(app.screenshot(), named: "show-page")
    }

    #else
    /// The same with the remote, from an episode's page opened by a link, as the Top Shelf opens one.
    @MainActor
    func testAnEpisodesPageBrowsesItsShowWithTheRemote() async throws {
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")
        XCTAssertTrue(app.descendants(matching: .any)["home.hero"].waitForExistence(timeout: uiTimeout), "Home never loaded")
        let episode = try await episodeId(named: "Low Tide")
        app.open(try XCTUnwrap(URL(string: "vinnyfin://item/\(episode)?type=Episode&name=Low%20Tide")))

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: uiTimeout), "The episode's page never opened")
        XCTAssertTrue(play.wait(for: \.hasFocus, toEqual: true, timeout: uiTimeout), "Focus didn't start on Play")
        keep(app.screenshot(), named: "tv-episode-page")

        let shown = app.buttons["seasonBrowser.episode.2"]
        focus(shown, in: app, moving: [.down])
        keep(app.screenshot(), named: "tv-season-row")
        XCUIRemote.shared.press(.left)
        let first = app.buttons["seasonBrowser.episode.1"]
        XCTAssertTrue(first.wait(for: \.hasFocus, toEqual: true, timeout: uiTimeout), "Left didn't move along the episodes")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(play.wait(for: \.hasFocus, toEqual: true, timeout: uiTimeout), "Picking an episode didn't go back up to Play")
        let marked = NSPredicate(format: "value CONTAINS 'viewing'")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: marked, object: first)], timeout: uiTimeout) == .completed,
                      "Picking another episode didn't show it")
        keep(app.screenshot(), named: "tv-another-episode")

        focus(app.buttons["detail.eyebrow"], in: app, moving: [.up])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["series.play"].waitForExistence(timeout: uiTimeout), "The show's name didn't lead to its page")
        keep(app.screenshot(), named: "tv-show-page")
    }

    /// The id of the showcase's episode called `name`.
    private func episodeId(named name: String) async throws -> String {
        func send(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> Data {
            var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
            request.httpMethod = method
            var authorization = #"MediaBrowser Client="vinnyfin UI tests", Device="Test runner", DeviceId="vinnyfin-browsing-tests", Version="1""#
            if let token { authorization += #", Token="\#(token)""# }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            return try await URLSession.shared.data(for: request).0
        }
        let signIn = try JSONSerialization.jsonObject(with: try await send(
            "/Users/AuthenticateByName", method: "POST", body: try JSONSerialization.data(withJSONObject: ["Username": "Alex", "Pw": ""])
        )) as? [String: Any]
        let token = try XCTUnwrap(signIn?["AccessToken"] as? String)
        let term = try XCTUnwrap(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let found = try JSONSerialization.jsonObject(with: try await send(
            "/Items?recursive=true&includeItemTypes=Episode&searchTerm=\(term)", token: token)) as? [String: Any]
        let items = try XCTUnwrap(found?["Items"] as? [[String: Any]])
        return try XCTUnwrap(items.first { $0["Name"] as? String == name }?["Id"] as? String, "No episode called \(name)")
    }
    #endif

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
