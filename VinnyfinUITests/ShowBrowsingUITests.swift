#if os(iOS) || os(tvOS)
import XCTest

/// Browses titles against the showcase server `AppStore/screenshots.sh` runs: a show from one of
/// its episodes, from the show's page to an episode's, along the season's episodes there, and back
/// to the show by its name; a title's page from a list and from a link; and a show marked watched.
/// Skipped without that server.
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
        // The episodes list as they scroll into view, under the show's hero and buttons.
        let details = app.buttons["episode.2.details"]
        for _ in 0..<6 where !details.exists { app.swipeUp() }
        tap(details)

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

    /// A title's page has what the list it came from leaves out: a film's overview from the Movies
    /// grid, and another's tagline from More Like This, whose posters have the title's menu.
    @MainActor
    func testATitlesPageHasItsDetails() async throws {
        let account = try await ShowcaseAccount(server: server)
        let copperline = try await account.item(named: "Copperline", type: "Movie")
        let lanterns = try await account.item(named: "Northbound Lanterns", type: "Movie")
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")

        tap(tab("Movies", in: app))
        tap(app.buttons["poster.Copperline"])
        let overview = try XCTUnwrap(copperline.overview)
        XCTAssertTrue(app.staticTexts[overview].waitForExistence(timeout: uiTimeout), "Copperline's page has no overview")
        if !copperline.isPlayed {
            let watched = app.switches["detail.watched"]
            XCTAssertTrue(watched.waitForExistence(timeout: uiTimeout))
            XCTAssertEqual(watched.label, "Watched")
            XCTAssertEqual(watched.value as? String, "0", "VoiceOver hears an unwatched title as watched")
        }
        keep(app.screenshot(), named: "movie-page")
        app.navigationBars.buttons.firstMatch.tap()

        tap(app.buttons["poster.Paper Comets"])
        let similar = app.buttons["poster.Northbound Lanterns"]
        XCTAssertTrue(similar.waitForExistence(timeout: uiTimeout), "Paper Comets has no More Like This")
        similar.press(forDuration: 1.2)
        let menuItem = app.buttons[lanterns.isPlayed ? "Mark as Unwatched" : "Mark as Watched"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: uiTimeout), "A More Like This poster has no menu")
        keep(app.screenshot(), named: "more-like-this-menu")
        // Beside the poster, clear of the menu over the page.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.72)).tap()
        XCTAssertTrue(menuItem.wait(for: \.exists, toEqual: false, timeout: uiTimeout), "The menu didn't close")

        tap(similar)
        let tagline = try XCTUnwrap(lanterns.tagline)
        XCTAssertTrue(app.staticTexts[tagline].waitForExistence(timeout: uiTimeout), "A title opened from More Like This has no tagline")
        keep(app.screenshot(), named: "similar-title-page")
    }

    /// A link opens its own title's page, not the one before's, even when it's a page of the same kind.
    @MainActor
    func testALinkOpensItsOwnTitle() async throws {
        let account = try await ShowcaseAccount(server: server)
        let portEllery = try await account.item(named: "Port Ellery", type: "Series")
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")
        tap(tab("Shows", in: app))
        tap(app.buttons["poster.The Long Field"])
        let first = app.buttons["episode.1"]
        let named = { (name: String) in
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", name), object: first)],
                           timeout: uiTimeout) == .completed
        }
        XCTAssertTrue(named("The Scarecrow Line"), "The Long Field's page doesn't list its episodes")

        app.open(try XCTUnwrap(URL(string: "vinnyfin://item/\(portEllery.id)?type=Series&name=Port%20Ellery")))
        XCTAssertTrue(named("The Night Ferry"), "The link to Port Ellery opened on The Long Field's episodes")
        keep(app.screenshot(), named: "linked-show")
    }

    /// Marking a show watched asks first, then marks its episodes on its page, without leaving it;
    /// Undo puts them back.
    @MainActor
    func testMarkingAShowWatchedMarksItsEpisodes() async throws {
        let account = try await ShowcaseAccount(server: server)
        let show = try await account.item(named: "The Long Field", type: "Series")
        // Unwatched again afterwards is all of it unwatched, which loses any of it watched before.
        try XCTSkipUnless(!show.isPlayed && (show.playedPercentage ?? 0) == 0, "Alex has watched some of The Long Field")
        addTeardownBlock { try await account.setPlayed(false, id: show.id) }
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")
        tap(tab("Shows", in: app))
        tap(app.buttons["poster.The Long Field"])

        let first = app.buttons["episode.1"]
        XCTAssertTrue(first.waitForExistence(timeout: uiTimeout), "The Long Field's page doesn't list its episodes")
        XCTAssertFalse(first.label.contains("Watched"))
        let watched = app.switches["detail.watched"]
        // The alert's button holds another with its identifier.
        let confirm = app.buttons["confirmation.confirm"].firstMatch
        tap(watched)
        XCTAssertTrue(confirm.waitForExistence(timeout: uiTimeout), "Marking the whole show didn't ask first")
        keep(app.screenshot(), named: "show-watched-question")
        tap(confirm)
        let badged = NSPredicate(format: "label CONTAINS 'Watched'")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: badged, object: first)], timeout: uiTimeout) == .completed,
                      "Marking the show watched didn't mark its episodes")
        XCTAssertEqual(watched.value as? String, "1")
        // A watched episode is no selection: SwiftUI took the badge's checkmark for one.
        XCTAssertFalse(first.isSelected, "VoiceOver hears a watched episode as selected")
        keep(app.screenshot(), named: "show-watched")

        let undo = app.buttons["toast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: uiTimeout), "Marking the whole show offered no Undo")
        tap(undo)
        let unbadged = NSPredicate(format: "NOT (label CONTAINS 'Watched')")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: unbadged, object: first)], timeout: uiTimeout) == .completed,
                      "Undo didn't put the show's episodes back")
        XCTAssertEqual(watched.value as? String, "0")
    }

    #else
    /// The same with the remote: from Continue Watching, and from an episode's page opened by a
    /// link, as the Top Shelf opens one.
    @MainActor
    func testAnEpisodesPageBrowsesItsShowWithTheRemote() async throws {
        let account = try await ShowcaseAccount(server: server)
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")
        XCTAssertTrue(app.descendants(matching: .any)["home.hero"].waitForExistence(timeout: uiTimeout), "Home never loaded")
        let play = app.buttons["detail.play"]

        // Resume joins Start Over to the row as the episode's details come, which mustn't take focus off it.
        // Select on a Continue Watching card opens the episode's page.
        if let resumed = try await account.resumedEpisode() {
            focusAlongItsRow(app.buttons["card.\(resumed)"], in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(play.waitForExistence(timeout: uiTimeout), "The episode's page never opened")
            XCTAssertTrue(play.wait(for: \.hasFocus, toEqual: true, timeout: uiTimeout), "Focus didn't start on Resume")
            keep(app.screenshot(), named: "tv-resumed-episode-page")
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(play.wait(for: \.exists, toEqual: false, timeout: uiTimeout))
        }

        let episode = try await account.item(named: "Low Tide", type: "Episode")
        app.open(try XCTUnwrap(URL(string: "vinnyfin://item/\(episode.id)?type=Episode&name=Low%20Tide")))
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

        // Go to Show is among the buttons beside Play, not a stop for focus above it.
        focus(app.buttons["detail.eyebrow"], in: app, moving: [.right])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["series.play"].waitForExistence(timeout: uiTimeout), "Go to Show didn't lead to the show's page")
        keep(app.screenshot(), named: "tv-show-page")
    }

    /// Back from playing some of an episode, focus is on Play again.
    @MainActor
    func testFocusComesBackToPlayAfterPlaying() async throws {
        let account = try await ShowcaseAccount(server: server)
        let episode = try await account.item(named: "Open Water", type: "Episode")
        // Unwatched again afterwards is how it was only if it was never played.
        try XCTSkipUnless(!episode.isPlayed && episode.position == 0, "Alex has played Open Water")
        let app = XCUIApplication()
        // Last in, first out: the app goes first, with its last report of the playback, which
        // would otherwise come after the episode is put back.
        addTeardownBlock { try await account.setPlayed(false, id: episode.id) }
        addTeardownBlock { app.terminate() }
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")
        XCTAssertTrue(app.descendants(matching: .any)["home.hero"].waitForExistence(timeout: uiTimeout), "Home never loaded")
        app.open(try XCTUnwrap(URL(string: "vinnyfin://item/\(episode.id)?type=Episode&name=Open%20Water")))

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: uiTimeout), "The episode's page never opened")
        XCTAssertTrue(play.wait(for: \.hasFocus, toEqual: true, timeout: uiTimeout), "Focus didn't start on Play")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["player.timeline"].waitForExistence(timeout: uiTimeout), "Play didn't play")
        try await Task.sleep(for: .seconds(5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: uiTimeout), "Menu didn't go back to the episode's page")
        XCTAssertTrue(play.wait(for: \.hasFocus, toEqual: true, timeout: uiTimeout), "Focus didn't come back to Play")
        keep(app.screenshot(), named: "tv-after-playing")
    }

    /// Moves focus down to the row `element` is in, then along the row to it.
    @MainActor
    private func focusAlongItsRow(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout), "\(element) never appeared", file: file, line: line)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        // Its frame is where to move from.
        XCTAssertTrue(focused.waitForExistence(timeout: uiTimeout), "No button has focus", file: file, line: line)
        // Level with it, allowing for focus lifting a card.
        let inItsRow = { focused.exists && abs(focused.frame.midY - element.frame.midY) < 40 }
        for _ in 0..<10 where !inItsRow() {
            XCUIRemote.shared.press(.down)
        }
        for _ in 0..<12 where !element.hasFocus {
            XCUIRemote.shared.press(element.frame.midX < focused.frame.midX ? .left : .right)
        }
        XCTAssertTrue(element.hasFocus, "\(element) never took focus", file: file, line: line)
    }
    #endif

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Alex's account on the showcase server, to look up its titles and put back what a test changes.
private struct ShowcaseAccount: Sendable {
    struct Item: Sendable {
        let id: String
        let overview: String?
        let tagline: String?
        let isPlayed: Bool
        let playedPercentage: Double?
        let position: Int
    }

    let server: String
    let token: String
    let userId: String

    init(server: String) async throws {
        self.server = server
        let signIn = try JSONSerialization.jsonObject(with: try await Self.send(
            server: server, "/Users/AuthenticateByName", method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["Username": "Alex", "Pw": ""])
        )) as? [String: Any]
        token = try XCTUnwrap(signIn?["AccessToken"] as? String)
        userId = try XCTUnwrap((signIn?["User"] as? [String: Any])?["Id"] as? String)
    }

    /// The showcase's `type` called `name`, as Alex has it.
    func item(named name: String, type: String) async throws -> Item {
        let term = try XCTUnwrap(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let found = try JSONSerialization.jsonObject(with: try await send(
            "/Users/\(userId)/Items?recursive=true&includeItemTypes=\(type)&searchTerm=\(term)&fields=Overview,Taglines")) as? [String: Any]
        let items = try XCTUnwrap(found?["Items"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first { $0["Name"] as? String == name }, "No \(type) called \(name)")
        let userData = item["UserData"] as? [String: Any]
        return Item(id: try XCTUnwrap(item["Id"] as? String),
                    overview: item["Overview"] as? String,
                    tagline: (item["Taglines"] as? [String])?.first,
                    isPlayed: userData?["Played"] as? Bool ?? false,
                    playedPercentage: userData?["PlayedPercentage"] as? Double,
                    position: userData?["PlaybackPositionTicks"] as? Int ?? 0)
    }

    /// The name of the episode Alex is partway through, which Continue Watching has.
    func resumedEpisode() async throws -> String? {
        let found = try JSONSerialization.jsonObject(with: try await send(
            "/Users/\(userId)/Items/Resume?mediaTypes=Video&includeItemTypes=Episode")) as? [String: Any]
        return (found?["Items"] as? [[String: Any]])?.first?["Name"] as? String
    }

    func setPlayed(_ played: Bool, id: String) async throws {
        _ = try await send("/Users/\(userId)/PlayedItems/\(id)", method: played ? "POST" : "DELETE")
    }

    private func send(_ path: String, method: String = "GET") async throws -> Data {
        try await Self.send(server: server, path, method: method, token: token)
    }

    private static func send(server: String, _ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        var authorization = #"MediaBrowser Client="vinnyfin UI tests", Device="Test runner", DeviceId="vinnyfin-browsing-tests", Version="1""#
        if let token { authorization += #", Token="\#(token)""# }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return data
    }
}
#endif
