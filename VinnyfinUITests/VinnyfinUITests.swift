#if !os(tvOS)
import XCTest

/// Drives the app against the local test server: signs in, browses with the A–Z index, plays a
/// chosen version until the clock moves, and turns on smart downloads for a show.
///
/// Expects the server and library `testserver/` sets up: a user "viewer" without a password,
/// "Big Test Movie" in 2160p, 1080p and 720p versions, and a two-season "Test Show". The
/// address comes from `VINNYFIN_TEST_SERVER` (pass `TEST_RUNNER_VINNYFIN_TEST_SERVER` to
/// xcodebuild) and defaults to http://localhost:8096.
final class VinnyfinUITests: XCTestCase {
    private let timeout = uiTimeout

    override func setUp() {
        continueAfterFailure = false
    }

    private var server: String {
        ProcessInfo.processInfo.environment["VINNYFIN_TEST_SERVER"] ?? "http://localhost:8096"
    }

    private func requireServer() async throws {
        let info = try XCTUnwrap(URL(string: server + "/System/Info/Public"))
        let answered = (try? await URLSession.shared.data(from: info)) != nil
        try XCTSkipUnless(answered, "No Jellyfin test server answers at \(server)")
    }

    @MainActor
    private func launchSignedIn() throws -> XCUIApplication {
        let app = XCUIApplication()
        #if os(visionOS)
        app.launchArguments = try signInArguments(server: server, username: "viewer")
        app.launch()
        signInIfNeeded(app)
        #else
        app.launch()
        signInIfNeeded(app, server: server, username: "viewer")
        #endif
        return app
    }

    // MARK: Server state

    private struct Authentication: Decodable {
        struct User: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "Id" }
        }

        let user: User
        let accessToken: String
        enum CodingKeys: String, CodingKey { case user = "User", accessToken = "AccessToken" }
    }

    private struct Items: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String
            enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
        }

        let items: [Item]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private func send(_ method: String, _ path: String, token: String? = nil, body: [String: String]? = nil) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        var authorization = #"MediaBrowser Client="vinnyfin UI tests", Device="Test runner", DeviceId="vinnyfin-ui-tests", Version="1""#
        if let token { authorization += #", Token="\#(token)""# }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) answered \(status)"])
        }
        return data
    }

    /// Marks every episode of a show unwatched for the test user, so a test starts from the
    /// library as set up rather than from wherever earlier viewing left it.
    private func markEveryEpisodeUnwatched(of show: String) async throws {
        let decoder = JSONDecoder()
        let signIn = try decoder.decode(Authentication.self, from: try await send("POST", "/Users/AuthenticateByName",
                                                                                 body: ["Username": "viewer", "Pw": ""]))
        let user = signIn.user.id
        let token = signIn.accessToken
        let term = try XCTUnwrap(show.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let series = try decoder.decode(Items.self, from: try await send(
            "GET", "/Items?userId=\(user)&includeItemTypes=Series&recursive=true&searchTerm=\(term)", token: token))
        let seriesId = try XCTUnwrap(series.items.first { $0.name == show }?.id, "No show named \(show)")
        let episodes = try decoder.decode(Items.self, from: try await send("GET", "/Shows/\(seriesId)/Episodes?userId=\(user)", token: token))
        for episode in episodes.items {
            _ = try await send("DELETE", "/UserPlayedItems/\(episode.id)?userId=\(user)", token: token)
        }
    }

    @MainActor
    func testBrowseAndPlayAVersion() async throws {
        try await requireServer()
        let app = try launchSignedIn()
        tap(app.buttons["Movies"].firstMatch)

        // The index jumps past everything before B.
        tap(app.buttons["index.B"])
        tap(app.buttons["poster.Big Test Movie"])

        let version = app.descendants(matching: .any)["detail.version"].firstMatch
        tap(version)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1080p'")).firstMatch)
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1080p'"), object: version)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: timeout), .completed, "Picking 1080p didn't pick it")
        tap(app.buttons["detail.play"])

        // The controls fade while playing; a tap on the picture brings them back.
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: timeout), "The player never opened")
        let picture = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let timeline = app.descendants(matching: .any)["player.timeline"].firstMatch
        let deadline = Date.now.addingTimeInterval(timeout)
        var position = ""
        while Date.now < deadline {
            if !timeline.exists { picture.tap() }
            if timeline.waitForExistence(timeout: 2), let value = timeline.value as? String {
                position = value
                if (timelinePosition(value)?.time ?? 0) > 0 { break }
            }
        }
        XCTAssertTrue((timelinePosition(position)?.time ?? 0) > 0, "Playback never got past the start (\(position))")
        // The controls may fade between looking and tapping; bring them back until Close takes.
        let close = app.buttons["player.close"]
        for _ in 0..<5 where app.buttons["player.close"].exists || !app.buttons["detail.play"].exists {
            if !close.exists { picture.tap() }
            if close.waitForExistence(timeout: 2), close.isHittable { close.tap() }
            if app.buttons["detail.play"].waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: timeout))
    }

    @MainActor
    func testSmartDownloadsKeepAShowAhead() async throws {
        try await requireServer()
        // Three episodes ahead needs three unwatched ones.
        try await markEveryEpisodeUnwatched(of: "Test Show")
        let app = try launchSignedIn()
        tap(app.buttons["Shows"].firstMatch)
        tap(app.buttons["poster.Test Show"])
        tap(app.descendants(matching: .any)["series.smartDownload"].firstMatch)
        tap(app.buttons["Next 3 Episodes"])

        tap(app.buttons["Downloads"].firstMatch)
        XCTAssertTrue(app.staticTexts["Keeping the next 3 downloaded"].waitForExistence(timeout: timeout),
                      "The smart download isn't listed")
        let downloaded = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'downloaded.'"))
        let three = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 3"), object: downloaded)
        XCTAssertEqual(XCTWaiter.wait(for: [three], timeout: 60), .completed, "Smart downloads didn't fetch three episodes")
    }
}
#endif

#if os(iOS) || os(tvOS)
import XCTest

/// Browses the library grids and Search against the showcase server `AppStore/screenshots.sh`
/// runs, as Alex, who has no favorite Drama movie: the grid keeps its place coming back to it,
/// its filters clear from an empty grid, Search's landing page has genres and recent searches,
/// a genre opens its grid, whose sort chip turns its order around, Search never says
/// "No Results" before it has looked, and a found episode leads to its show. On Apple TV, a
/// focused result is wholly on screen. Skipped without that server. Nothing on the server is
/// changed; what the app keeps on the device, Movies' filters and the recent searches, each test
/// leaves as it found it.
final class LibraryAndSearchUITests: XCTestCase {
    private var server = ""

    override func setUp() async throws {
        continueAfterFailure = false
        let address = ProcessInfo.processInfo.environment["VINNYFIN_SCREENSHOT_SERVER"]
        try XCTSkipUnless(address != nil, "Needs the showcase server AppStore/screenshots.sh runs")
        server = address ?? ""
    }

    @MainActor
    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "Alex")
        return app
    }

    #if os(iOS)
    @MainActor
    func testTheGridKeepsItsPlaceComingBackToIt() {
        let app = launchSignedIn()
        tap(tab("Movies", in: app))
        // Down to the last row.
        let last = app.buttons["poster.Winter at Halden Ridge"]
        XCTAssertTrue(app.buttons["poster.Amber Cartographers"].waitForExistence(timeout: uiTimeout), "Movies never loaded")
        for _ in 0..<6 where !(last.exists && last.isHittable) { app.swipeUp() }
        XCTAssertTrue(last.isHittable, "The grid never reached its last row")
        let first = firstVisiblePoster(in: app)
        XCTAssertNotNil(first, "No poster is on screen")
        keep(app.screenshot(), named: "grid-scrolled")

        // To a title's page and back.
        tap(last)
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: uiTimeout), "The title's page never opened")
        tap(app.buttons["BackButton"])
        XCTAssertTrue(last.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(firstVisiblePoster(in: app), first, "Back from a title, the grid moved")
        keep(app.screenshot(), named: "grid-after-back")

        // To another tab and back.
        tap(tab("Shows", in: app))
        XCTAssertTrue(app.buttons["poster.Port Ellery"].waitForExistence(timeout: uiTimeout), "Shows never loaded")
        tap(tab("Movies", in: app))
        XCTAssertTrue(last.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(firstVisiblePoster(in: app), first, "Back from another tab, the grid moved")
    }

    @MainActor
    func testClearFiltersResetsAnEmptyGrid() {
        let app = launchSignedIn()
        tap(tab("Movies", in: app))
        let amber = app.buttons["poster.Amber Cartographers"]
        XCTAssertTrue(amber.waitForExistence(timeout: uiTimeout), "Movies never loaded")
        let menu = app.buttons["library.sortFilter"]
        tap(menu)
        tap(app.buttons["Favorites"])
        tap(menu)
        tap(app.buttons["All Genres"])
        tap(app.buttons["Drama"])
        // The genres stay open for picking another; a tap outside closes them.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()

        let clear = app.buttons["library.clearFilters"]
        XCTAssertTrue(clear.waitForExistence(timeout: uiTimeout), "An empty filtered grid offers no way to clear its filters")
        XCTAssertTrue(app.staticTexts["No Matches"].exists)
        XCTAssertEqual(menu.label, "Sort and Filter, filtered to Favorites and Drama")
        keep(app.screenshot(), named: "no-matches")
        clear.tap()
        XCTAssertTrue(amber.waitForExistence(timeout: uiTimeout), "Clear Filters didn't bring the grid back")
        XCTAssertFalse(clear.exists)
        XCTAssertEqual(menu.label, "Sort and Filter")
    }

    @MainActor
    func testSearchLandsOnGenresAndRecentSearches() {
        let app = launchSignedIn()
        tap(tab("Search", in: app))
        XCTAssertTrue(app.buttons["genre.Drama"].waitForExistence(timeout: uiTimeout), "Search's landing page has no genres")
        keep(app.screenshot(), named: "search-landing")

        let field = app.searchFields.firstMatch
        tap(field)
        field.typeText("port\n")
        XCTAssertTrue(app.buttons["poster.Port Ellery"].waitForExistence(timeout: uiTimeout), "Searching \"port\" never found Port Ellery")
        // Emptied, the field gives back the landing page, with the search just made.
        tap(field.buttons["Clear text"])
        let recent = app.buttons["search.recent.port"]
        XCTAssertTrue(recent.waitForExistence(timeout: uiTimeout), "The search just made isn't among the recent ones")
        tap(recent)
        XCTAssertTrue(app.buttons["poster.Port Ellery"].waitForExistence(timeout: uiTimeout), "A recent search didn't search again")

        tap(field.buttons["Clear text"])
        tap(app.buttons["search.clearRecents"])
        XCTAssertTrue(recent.waitForNonExistence(timeout: uiTimeout), "Clear left the recent searches")
        XCTAssertTrue(app.buttons["genre.Drama"].exists)
    }

    @MainActor
    func testAGenreOpensItsGridBestFirst() {
        let app = launchSignedIn()
        tap(tab("Search", in: app))
        tap(app.buttons["genre.Drama"])
        XCTAssertTrue(app.navigationBars["Drama"].waitForExistence(timeout: uiTimeout), "The Drama tile didn't open its grid")
        // Its movies and shows together, the best rated first.
        let sort = app.buttons["library.sortChip"]
        XCTAssertTrue(sort.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(sort.label, "Sorted by Rating, Highest First")
        XCTAssertTrue(app.buttons["poster.Port Ellery"].waitForExistence(timeout: uiTimeout), "Drama's grid doesn't have the show Port Ellery")
        XCTAssertTrue(app.buttons["poster.The Last Ferry to Ilsa"].exists, "Drama's grid doesn't have the movie The Last Ferry to Ilsa")
        let first = firstVisiblePoster(in: app)
        keep(app.screenshot(), named: "genre-grid")

        tap(sort)
        XCTAssertTrue(sort.wait(for: \.label, toEqual: "Sorted by Rating, Lowest First", timeout: uiTimeout), "The sort chip didn't turn the order around")
        let deadline = Date.now.addingTimeInterval(uiTimeout)
        while Date.now < deadline, firstVisiblePoster(in: app) == first { RunLoop.current.run(until: .now.addingTimeInterval(0.25)) }
        XCTAssertNotEqual(firstVisiblePoster(in: app), first, "The grid's order didn't change")
    }

    @MainActor
    func testSearchNeverSaysNoResultsBeforeItHasLooked() {
        let app = launchSignedIn()
        tap(tab("Search", in: app))
        let field = app.searchFields.firstMatch
        tap(field)
        let noResults = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results'")).firstMatch
        let found = app.buttons["poster.Port Ellery"]
        var looks = 0
        /// Looks again and again, as fast as the accessibility snapshots come, until `done`.
        func watch(for seconds: TimeInterval, until done: () -> Bool = { false }) {
            let deadline = Date.now.addingTimeInterval(seconds)
            while Date.now < deadline, !done() {
                XCTAssertFalse(noResults.exists, "Search said No Results while it was still looking (look \(looks))")
                looks += 1
            }
        }
        field.typeText("p")
        watch(for: 0.4)
        field.typeText("ort")
        watch(for: uiTimeout) { found.exists }
        XCTAssertTrue(found.exists, "Searching \"port\" never found Port Ellery")
        XCTAssertFalse(noResults.exists)
        XCTAssertGreaterThan(looks, 3)
    }

    @MainActor
    func testASearchedEpisodesMenuGoesToItsShow() {
        let app = launchSignedIn()
        tap(tab("Search", in: app))
        let field = app.searchFields.firstMatch
        tap(field)
        field.typeText("ferry\n")
        let episode = app.buttons["card.The Night Ferry"]
        XCTAssertTrue(episode.waitForExistence(timeout: uiTimeout), "Searching \"ferry\" never found The Night Ferry")
        episode.press(forDuration: 1.2)
        let goToShow = app.buttons["Go to Show"]
        XCTAssertTrue(goToShow.waitForExistence(timeout: uiTimeout), "A found episode's menu doesn't lead to its show")
        keep(app.screenshot(), named: "episode-menu")
        goToShow.tap()
        XCTAssertTrue(app.navigationBars["Port Ellery"].waitForExistence(timeout: uiTimeout), "Go to Show didn't open the show")
    }

    /// The first poster on screen, reading across and then down.
    @MainActor
    private func firstVisiblePoster(in app: XCUIApplication) -> String? {
        let screen = app.windows.firstMatch.frame
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'poster.'")).allElementsBoundByIndex
            .map { ($0.identifier, $0.frame) }
            .filter { $0.1.minY >= screen.minY && $0.1.minY < screen.maxY }
            .min { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }?.0
    }

    #else
    @MainActor
    func testAFocusedSearchResultIsWhollyOnScreen() {
        let app = launchSignedIn()
        XCTAssertTrue(app.descendants(matching: .any)["home.hero"].waitForExistence(timeout: uiTimeout), "Home never loaded")
        // Left into the sidebar, then to Search.
        let sidebar = app.collectionViews["Sidebar"]
        let focusedRow = sidebar.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<12 where !focusedRow.waitForExistence(timeout: 1) { XCUIRemote.shared.press(.left) }
        focus(sidebar.buttons["Search"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiTimeout), "Search's keyboard never showed")
        app.typeText("st")
        XCTAssertTrue(app.buttons["poster.Starfall Station"].waitForExistence(timeout: uiTimeout), "Searching \"st\" found nothing")

        // Down the rows to the episodes.
        let episode = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH 'card.'")).firstMatch
        for _ in 0..<10 where !episode.waitForExistence(timeout: 1) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(episode.exists, "Focus never reached the episodes")
        // Once the scroll to it has settled.
        Thread.sleep(forTimeInterval: 2)
        keep(app.screenshot(), named: "tv-search-episodes")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(episode.frame), "The focused episode \(episode.frame) isn't wholly on screen \(screen)")
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
