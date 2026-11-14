#if os(iOS)
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

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
