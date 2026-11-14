import CoreGraphics
import Foundation
import ImageIO
import Nuke
import Testing
@testable import vinnyfin

/// Cards take the watch state a playback that ended left their titles in.
struct EndedPlaybackTests {
    @Test func putsInTheWatchStateOfWhatWasPlayedOnly() {
        var played = JellyfinItem(id: "e1", name: "Episode 1", type: "Episode")
        played.overview = "Kept as the list loaded it."
        played.userData = UserItemData(playbackPositionTicks: 0)
        var show = JellyfinItem(id: "s1", name: "Show", type: "Series")
        show.userData = UserItemData(unplayedItemCount: 8)
        let other = JellyfinItem(id: "m1", name: "Movie", type: "Movie")
        let ended = EndedPlayback(count: 1, userData: [
            "e1": UserItemData(playbackPositionTicks: 1_260_000_000, playedPercentage: 33),
            "s1": UserItemData(unplayedItemCount: 7),
        ])

        let cards = ended.applied(to: [played, show, other])
        #expect(cards.map(\.id) == ["e1", "s1", "m1"])
        #expect(cards[0].resumeSeconds == 126)
        #expect(cards[0].overview == "Kept as the list loaded it.")
        #expect(cards[1].userData?.unplayedItemCount == 7)
        #expect(cards[2] == other)
    }
}

struct LibraryIndexTests {
    /// The server's counts for a list with `leading` titles before "a", `letters` titles under
    /// each letter, and `trailing` after "z".
    private static func index(leading: Int = 0, _ letters: [String: Int], trailing: Int = 0) -> LibraryIndex {
        var before: [Int] = []
        var running = leading
        for boundary in LibraryIndex.boundaries {
            before.append(running)
            running += letters[boundary.uppercased()] ?? 0
        }
        return LibraryIndex(countsBefore: before, count: running + trailing)
    }

    @Test func sectionsFollowTheServersCounts() {
        let index = Self.index(leading: 3, ["A": 5, "C": 2, "Z": 1])
        #expect(index.sections.map(\.letter) == ["#", "A", "C", "Z"])
        #expect(index.sections.map(\.range) == [0..<3, 3..<8, 8..<10, 10..<11])
    }

    @Test func namesAfterZGoLastUnderTheNumberSign() {
        let index = Self.index(["B": 2], trailing: 4)
        #expect(index.sections.map(\.letter) == ["B", "#"])
        #expect(index.sections.last?.range == 2..<6)
    }

    @Test func jumpsToTheNextLetterThatExists() {
        let index = Self.index(leading: 1, ["A": 2, "E": 3, "H": 1])
        #expect(index.section(for: "A")?.letter == "A")
        #expect(index.section(for: "B")?.letter == "E")
        #expect(index.section(for: "#")?.range == 0..<1)
        #expect(index.section(for: "Y")?.letter == "H")
        #expect(index.section(for: "?") == nil)
    }

    @Test func theNumberSignJumpsToTheEndWhenNothingComesFirst() {
        let index = Self.index(["A": 2], trailing: 2)
        #expect(index.section(for: "#")?.range == 2..<4)
    }

    @Test func countsThatDisagreeStayInOrderAndInTheList() {
        // Counted while titles were being added: a later boundary saw fewer, the total more.
        var before = Array(repeating: 10, count: LibraryIndex.boundaries.count)
        before[1] = 8
        before[26] = 40
        let index = LibraryIndex(countsBefore: before, count: 30)
        #expect(index.sections.map(\.range) == [0..<10, 10..<30])
        #expect(index.sections.map(\.letter) == ["#", "Z"])
    }

    @Test func boundariesAreTheLettersThenTheCharacterAfterZ() {
        #expect(LibraryIndex.boundaries.count == 27)
        #expect(LibraryIndex.boundaries.first == "a")
        #expect(LibraryIndex.boundaries.last == "{")
        #expect(LibraryIndex.alphabet == ["#"] + LibraryIndex.boundaries.dropLast().map { $0.uppercased() })
    }

    @Test func aLetterStartsAfterTheTitlesBeforeItsLowercaseForm() {
        #expect(LibraryIndex.boundary(for: "M") == "m")
        #expect(LibraryIndex.boundary(for: "#") == nil)
        #expect(LibraryIndex.boundary(for: "?") == nil)
    }

    @Test func aPositionIsInItsSectionsLetter() {
        let index = Self.index(leading: 3, ["A": 5, "C": 2])
        #expect(index.letter(at: 0) == "#")
        #expect(index.letter(at: 3) == "A")
        #expect(index.letter(at: 7) == "A")
        #expect(index.letter(at: 8) == "C")
        #expect(index.letter(at: 10) == nil)
    }
}

struct CardRowScrollTests {
    /// A 230-point card and the 48 points after it.
    private let stride: CGFloat = 278

    @Test func goesOnToTheNextCardStartInTheDirectionFocusMoved() {
        // Focus moving right asks for just enough to show the card past the focused one.
        #expect(CardRowScrollBehavior.offset(from: 0, toward: 120, stride: stride, limit: 5_000) == 278)
        #expect(CardRowScrollBehavior.offset(from: 556, toward: 400, stride: stride, limit: 5_000) == 278)
    }

    @Test func staysOnACardStartAskedForOrARoundingErrorPastIt() {
        #expect(CardRowScrollBehavior.offset(from: 0, toward: 556, stride: stride, limit: 5_000) == 556)
        #expect(CardRowScrollBehavior.offset(from: 0, toward: 556.0004, stride: stride, limit: 5_000) == 556)
        #expect(CardRowScrollBehavior.offset(from: 834, toward: 555.9996, stride: stride, limit: 5_000) == 556)
    }

    @Test func staysInsideTheRow() {
        #expect(CardRowScrollBehavior.offset(from: 834, toward: 1_000, stride: stride, limit: 900) == 900)
        #expect(CardRowScrollBehavior.offset(from: 278, toward: -20, stride: stride, limit: 900) == 0)
        // A row narrower than the screen doesn't scroll.
        #expect(CardRowScrollBehavior.offset(from: 0, toward: 40, stride: stride, limit: -300) == 0)
    }

    @Test func leavesAScrollThatGoesNowhereAlone() {
        #expect(CardRowScrollBehavior.offset(from: 300, toward: 300, stride: stride, limit: 5_000) == 300)
    }
}

struct RowHoldTests {
    private let row = CGRect(x: 0, y: 1_500, width: 1_920, height: 520)

    @Test func holdsARowsTopBelowTheMargin() {
        #expect(RowHold.top.offset(for: row, top: 80, viewport: 1_080, content: 6_000) == 1_420)
    }

    @Test func scrollsTheFirstRowJustIntoViewUnderTheBanner() {
        #expect(RowHold.whole.offset(for: row, top: 80, viewport: 1_080, content: 6_000) == 940)
    }

    @Test func staysInsideThePage() {
        // The last row can't come up to the top: the page ends first.
        #expect(RowHold.top.offset(for: row, top: 80, viewport: 1_080, content: 2_100) == 1_020)
        // A row already in view at the top of the page leaves it there.
        let first = CGRect(x: 0, y: 0, width: 1_920, height: 520)
        #expect(RowHold.whole.offset(for: first, top: 80, viewport: 1_080, content: 6_000) == 0)
        #expect(RowHold.top.offset(for: first, top: 80, viewport: 1_080, content: 6_000) == 0)
    }
}

struct PageWindowTests {
    @Test func pagesCoverTheListWithAShortLastOne() {
        let window = PageWindow(pageSize: 100, count: 250)
        #expect(window.pageCount == 3)
        #expect(window.page(containing: 199) == 1)
        #expect(window.range(of: 0) == 0..<100)
        #expect(window.range(of: 2) == 200..<250)
    }

    @Test func loadsThePageOnScreenThenTheNextThenThePrevious() {
        let window = PageWindow(pageSize: 100, count: 20_000, lookahead: 2)
        #expect(window.pagesToLoad(around: 450) == [4, 5, 3, 6, 2])
    }

    @Test func staysInsideTheList() {
        let window = PageWindow(pageSize: 100, count: 250)
        #expect(window.pagesToLoad(around: 0) == [0, 1])
        #expect(window.pagesToLoad(around: 249) == [2, 1])
        #expect(PageWindow(pageSize: 100, count: 0).pagesToLoad(around: 0).isEmpty)
    }

    @Test func keepsOnlyThePagesNearTheOneOnScreen() {
        let window = PageWindow(pageSize: 100, count: 20_000, retained: 4)
        #expect(window.keeps(8, around: 400))
        #expect(window.keeps(0, around: 400))
        #expect(!window.keeps(9, around: 400))
        // However far the list scrolls, as many pages stay.
        let kept = (0..<window.pageCount).filter { window.keeps($0, around: 15_000) }
        #expect(kept.count == 9)
    }
}

struct FocusWindowTests {
    @Test func holdsTheFirstRowsAtFirst() {
        #expect(FocusWindow().range(count: 21_000, columns: 6) == 0..<360)
        #expect(FocusWindow().range(count: 40) == 0..<40)
    }

    @Test func staysPutWhileFocusIsAwayFromItsEnds() {
        var window = FocusWindow()
        window.follow(200, count: 21_000, columns: 6)
        #expect(window.start == 0)
    }

    @Test func centersOnFocusNearItsEndAndComesBackNearItsStart() {
        var window = FocusWindow()
        window.follow(300, count: 21_000, columns: 6)
        // Focus is in row 50; the window starts 30 rows before it.
        #expect(window.range(count: 21_000, columns: 6) == 120..<480)
        window.follow(125, count: 21_000, columns: 6)
        #expect(window.start == 0)
    }

    @Test func endsWithTheListsLastRow() {
        var window = FocusWindow()
        window.follow(50, count: 70)
        #expect(window.range(count: 70) == 10..<70)
        // At the list's own end there is nowhere further to go.
        window.follow(65, count: 70)
        #expect(window.start == 10)
    }

    @Test func centersOnAJumpAtTheStartOfARow() {
        var window = FocusWindow()
        window.center(on: 5_000, count: 21_000, columns: 6)
        #expect(window.start == 4_818)
        #expect(window.range(count: 21_000, columns: 6).contains(5_000))
    }
}

@MainActor
struct LoadQueueTests {
    /// Lets the queue's tasks run until they next wait.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func runsAFewAtOnceInTheOrderWanted() {
        let queue = LoadQueue<Int>(width: 2) { _ in try? await Task.sleep(for: .seconds(30)) }
        queue.want([1, 2, 3])
        #expect(queue.underWay == [1, 2])
        #expect(queue.queued == [3])
        queue.want([2, 4, 3])
        #expect(queue.queued == [3, 4])
        queue.cancelAll()
    }

    @Test func dropsAndCancelsWhatIsNoLongerWanted() {
        let queue = LoadQueue<Int>(width: 2) { _ in try? await Task.sleep(for: .seconds(30)) }
        queue.want([1, 2, 3, 4])
        queue.retain { $0 != 1 && $0 != 4 }
        #expect(queue.underWay == [2, 3])
        #expect(queue.queued.isEmpty)
        queue.cancelAll()
        #expect(queue.underWay.isEmpty)
    }

    @Test func startsTheNextAsEachFinishes() async {
        var order: [Int] = []
        let queue = LoadQueue<Int>(width: 1) { order.append($0) }
        queue.want([1, 2, 3])
        await settle()
        #expect(order == [1, 2, 3])
        #expect(queue.underWay.isEmpty)
    }

    @Test func aLoadWantedAgainAfterCancellingIsNotCutShortByTheOldOne() async {
        var runs = 0
        let queue = LoadQueue<Int>(width: 1) { _ in
            runs += 1
            try? await Task.sleep(for: runs == 1 ? .zero : .seconds(30))
        }
        queue.want([1])
        queue.retain { _ in false }
        queue.want([1])
        await settle()
        // The first run has finished; the second is still under way.
        #expect(runs == 2)
        #expect(queue.underWay == [1])
        queue.cancelAll()
    }
}

struct HomeRowsTests {
    private static func title(_ id: String, _ type: String = "Movie", genres: [String] = []) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: "Title \(id)", type: type)
        item.genres = genres
        return item
    }

    private let inputs = HomeRows.Inputs(
        watched: [title("a", genres: ["Science Fiction"]), title("b", "Series", genres: ["Drama"]),
                  title("c", genres: ["Science Fiction", "Comedy"]), title("d")],
        favorites: [title("e"), title("a")],
        movieGenres: [GenreSize(name: "Science Fiction", count: 50), GenreSize(name: "Drama", count: 100),
                      GenreSize(name: "Comedy", count: 30), GenreSize(name: "Western", count: 10), GenreSize(name: "Tiny", count: 2)],
        showGenres: [GenreSize(name: "Drama", count: 80), GenreSize(name: "Western", count: 7)]
    )

    private func rows(_ inputs: HomeRows.Inputs, seed: UInt64 = 7) -> [HomeRow] {
        var random = SeededRandom(seed: seed)
        return HomeRows.assemble(inputs, using: &random)
    }

    @Test func theSameSeedPicksTheSameRows() {
        var inputs = inputs
        inputs.favorites = (0..<10).map { Self.title("f\($0)") }
        #expect(rows(inputs, seed: 42) == rows(inputs, seed: 42))
        let picks = Set((0..<20).map { seed in rows(inputs, seed: seed).filter { $0.id.hasPrefix("moreLike.") }.map(\.id) })
        #expect(picks.count > 1, "different seeds pick different favorites")
    }

    @Test func startsWithWhatToWatchNextAndWhatsNew() {
        #expect(rows(inputs).prefix(3).map(\.id) == ["continueWatching", "recentMovies", "recentShows"])
    }

    @Test func becauseYouWatchedTheLastFewTitles() {
        let ids = rows(inputs).map(\.id)
        #expect(ids.filter { $0.hasPrefix("becauseYouWatched.") } == ["becauseYouWatched.a", "becauseYouWatched.b", "becauseYouWatched.c"])
        // A favorite already in a Because You Watched row gets no row of its own.
        #expect(ids.filter { $0.hasPrefix("moreLike.") } == ["moreLike.e"])
    }

    @Test func genresWatchedMostComeFirstThenTheBiggest() {
        let genres = HomeRows.rankedGenres(inputs)
        #expect(genres.map { "\($0.type) \($0.name)" } == [
            "Movie Science Fiction", "Movie Drama", "Series Drama", "Movie Comedy", "Movie Western", "Series Western",
        ])
        let rowTitles = rows(inputs).filter { $0.id.hasPrefix("genre.") }.map(\.list.title)
        #expect(rowTitles.first == "Science Fiction Movies")
        #expect(!rowTitles.contains("Tiny Movies"))
    }

    @Test func somethingDifferentIsAGenreNotWatched() {
        #expect(rows(inputs).contains { $0.id == "somethingDifferent.Western" })
        var random = SeededRandom(seed: 1)
        #expect(HomeRows.differentGenre(HomeRows.Inputs(), using: &random) == nil)
    }

    @Test func somethingDifferentNeedsSomethingWatchedFirst() {
        var inputs = inputs
        inputs.watched = []
        for seed in UInt64(0)..<20 {
            var random = SeededRandom(seed: seed)
            #expect(HomeRows.differentGenre(inputs, using: &random) == nil)
        }
        #expect(!rows(inputs).contains { $0.id.hasPrefix("somethingDifferent.") })
    }

    @Test func somethingDifferentIsNeverAGenreWatchedOrStarted() {
        var inputs = inputs
        // Drama is the biggest by far, and watched once, the least of any genre watched.
        inputs.watched = [Self.title("w", genres: ["Drama"])]
        for seed in UInt64(0)..<20 {
            var random = SeededRandom(seed: seed)
            let genre = HomeRows.differentGenre(inputs, using: &random)
            #expect(genre != nil && genre != "Drama")
        }
        // Every other genre big enough for a row is in something started or in Continue Watching.
        inputs.started = [Self.title("s1", genres: ["Science Fiction", "Comedy"]), Self.title("s2", "Series", genres: ["Western"])]
        for seed in UInt64(0)..<20 {
            var random = SeededRandom(seed: seed)
            #expect(HomeRows.differentGenre(inputs, using: &random) == nil)
        }
    }

    @Test func continueWatchingStandsInOnlyWhenItHadTitles() {
        #expect(HomeRows.placeholders(continueWatching: true).map(\.id) == ["continueWatching", "recentMovies", "recentShows"])
        #expect(HomeRows.placeholders(continueWatching: false).map(\.id) == ["recentMovies", "recentShows"])
    }

    @MainActor @Test func everyRowIsDistinctAndOpensAListItsGridCanSort() {
        let rows = rows(inputs)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for row in rows {
            guard case .items(let query) = row.list.source else { continue }
            #expect(LibraryGridView.Sort(query) != nil, "\(row.id) sorts by \(query.sortBy)")
        }
    }

    @Test func leavesOutRowsThereIsNothingFor() {
        let ids = rows(HomeRows.Inputs()).map(\.id)
        #expect(ids == ["continueWatching", "recentMovies", "recentShows", "newMovies", "topMovies",
                        "newShows", "topShows", "collections", "recentlyWatched"])
    }

    @Test func episodesStandForTheirShowsOnce() {
        var first = JellyfinItem(id: "e1", name: "Pilot", type: "Episode")
        first.seriesId = "s1"
        var second = JellyfinItem(id: "e2", name: "Two", type: "Episode")
        second.seriesId = "s1"
        var orphan = JellyfinItem(id: "e3", name: "Lost", type: "Episode")
        orphan.seriesId = "gone"
        let titles = HomeRows.titles(played: [first, Self.title("m"), second, orphan],
                                     shows: [Self.title("s1", "Series", genres: ["Drama"])])
        #expect(titles.map(\.id) == ["s1", "m"])
        #expect(titles.first?.genres == ["Drama"])
    }
}

struct HomeFeedTests {
    @Test func hasNoTitlesOnlyWithoutMoviesAndShows() {
        #expect(HomeFeed.hasNoTitles([:]))
        #expect(HomeFeed.hasNoTitles([HomeRows.recentMovies.id: [], HomeRows.recentShows.id: [], HomeRows.continueWatching.id: []]))
        #expect(!HomeFeed.hasNoTitles([HomeRows.recentMovies.id: [JellyfinItem(id: "m", name: "Movie", type: "Movie")]]))
        #expect(!HomeFeed.hasNoTitles([HomeRows.recentShows.id: [JellyfinItem(id: "s", name: "Show", type: "Series")]]))
    }

    private static func title(_ id: String, _ type: String = "Movie", played: Bool = false, favorite: Bool = false,
                              resumeTicks: Int64? = nil) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: "Title \(id)", type: type)
        item.userData = UserItemData(playbackPositionTicks: resumeTicks, isFavorite: favorite, played: played)
        return item
    }

    @Test func aTitleWatchedLeavesContinueWatchingAndUnwatchedFavoritesOnly() {
        var episode = Self.title("e1", "Episode", favorite: true, resumeTicks: 600_000_000)
        var items: [HomeRow.ID: [JellyfinItem]] = [
            HomeRows.continueWatching.id: [Self.title("m1", resumeTicks: 1), episode, Self.title("m2", resumeTicks: 1)],
            HomeRows.unwatchedFavorites.id: [episode],
            HomeRows.recentlyWatched.id: [episode],
            HomeRows.favorites.id: [episode],
        ]
        var removed: HomeFeed.Removals = [:]
        episode.userData?.played = true
        episode.userData?.playbackPositionTicks = 0
        let left = HomeFeed.replace(episode, in: &items, removed: &removed)

        #expect(left == [HomeRows.continueWatching.id, HomeRows.unwatchedFavorites.id])
        #expect(items[HomeRows.continueWatching.id]?.map(\.id) == ["m1", "m2"])
        #expect(items[HomeRows.unwatchedFavorites.id]?.isEmpty == true)
        #expect(items[HomeRows.recentlyWatched.id]?.first?.isPlayed == true)
        #expect(items[HomeRows.favorites.id]?.first?.isPlayed == true)
    }

    @Test func aTitleNoLongerAFavoriteLeavesTheFavoritesRows() {
        var movie = Self.title("m1", favorite: true)
        var items: [HomeRow.ID: [JellyfinItem]] = [
            HomeRows.favorites.id: [Self.title("a", favorite: true), movie],
            HomeRows.unwatchedFavorites.id: [movie, Self.title("b", favorite: true)],
            HomeRows.topMovies.id: [movie],
        ]
        var removed: HomeFeed.Removals = [:]
        movie.userData?.isFavorite = false
        let left = HomeFeed.replace(movie, in: &items, removed: &removed)

        #expect(left == [HomeRows.favorites.id, HomeRows.unwatchedFavorites.id])
        #expect(items[HomeRows.favorites.id]?.map(\.id) == ["a"])
        #expect(items[HomeRows.unwatchedFavorites.id]?.map(\.id) == ["b"])
        #expect(items[HomeRows.topMovies.id]?.first?.isFavorite == false)
    }

    @Test func aChangeUndoneByTheServerPutsTheTitleBackWhereItWas() {
        let movie = Self.title("m1", resumeTicks: 600_000_000)
        var items: [HomeRow.ID: [JellyfinItem]] = [
            HomeRows.continueWatching.id: [Self.title("a", resumeTicks: 1), movie, Self.title("b", resumeTicks: 1)],
        ]
        var removed: HomeFeed.Removals = [:]
        var watched = movie
        watched.userData?.played = true
        _ = HomeFeed.replace(watched, in: &items, removed: &removed)
        #expect(items[HomeRows.continueWatching.id]?.map(\.id) == ["a", "b"])

        let left = HomeFeed.replace(movie, in: &items, removed: &removed)
        #expect(left.isEmpty)
        #expect(items[HomeRows.continueWatching.id]?.map(\.id) == ["a", "m1", "b"])
        #expect(removed[HomeRows.continueWatching.id]?.isEmpty == true)
    }
}

struct FeaturedRotationTests {
    private let items = ["a", "b", "c", "d"].map { JellyfinItem(id: $0, name: $0.uppercased(), type: "Movie") }

    @Test func staysOnTheSameTitleWhenTheTitlesComeBackInAnotherOrder() {
        #expect(FeaturedRotation.position(of: "c", in: items) == 2)
        // Continue Watching put a movie in progress first, as after playing it.
        let reordered = [items[3], items[2], items[0], items[1]]
        #expect(reordered[FeaturedRotation.position(of: "c", in: reordered)].id == "c")
    }

    @Test func startsAgainFromTheFirstWhenTheTitleShownIsGone() {
        #expect(FeaturedRotation.position(of: "gone", in: items) == 0)
        #expect(FeaturedRotation.position(of: nil, in: items) == 0)
    }

    @Test func turnsRoundFromTheEndToTheStart() {
        #expect(FeaturedRotation.id(after: "c", by: 1, in: items) == "d")
        #expect(FeaturedRotation.id(after: "d", by: 1, in: items) == "a")
        #expect(FeaturedRotation.id(after: "a", by: -1, in: items) == "d")
        #expect(FeaturedRotation.id(after: nil, by: 1, in: items) == "b")
        #expect(FeaturedRotation.id(after: "a", by: 1, in: []) == nil)
    }

    @Test func goesOnToTheNextTitleLeftWhenTheOneShownLeaves() {
        // "b" was started, so it's in Continue Watching now and out of the banner.
        #expect(FeaturedRotation.id(keeping: "b", from: ["a", "b", "c", "d"], in: ["a", "c", "d"]) == "c")
        #expect(FeaturedRotation.id(keeping: "d", from: ["a", "b", "c", "d"], in: ["a", "b", "c"]) == "a")
        #expect(FeaturedRotation.id(keeping: "c", from: ["a", "b", "c", "d"], in: ["d", "c"]) == "c")
        #expect(FeaturedRotation.id(keeping: "x", from: ["a"], in: ["b"]) == "b")
        #expect(FeaturedRotation.id(keeping: nil, from: [], in: ["a"]) == nil)
    }

    @Test func pagesGoRoundWithACopyAtEachEnd() {
        // Four titles: the last, the four, then the first again.
        #expect(FeaturedRotation.pageCount(for: 4) == 6)
        #expect((0..<6).map { FeaturedRotation.title(atPage: $0, count: 4) } == [3, 0, 1, 2, 3, 0])
        #expect(FeaturedRotation.page(ofTitle: 0, count: 4) == 1)
        #expect(FeaturedRotation.page(ofTitle: 3, count: 4) == 4)
        // One title has a page of its own and nothing to go round to.
        #expect(FeaturedRotation.pageCount(for: 1) == 1)
        #expect(FeaturedRotation.title(atPage: 0, count: 1) == 0)
        #expect(FeaturedRotation.page(ofTitle: 0, count: 1) == 0)
    }
}

/// What the banner features.
struct FeaturedTitlesTests {
    private static func title(_ id: String, _ type: String = "Movie", logo: Bool = true, backdrop: Bool = true,
                              played: Bool = false, resumeTicks: Int64? = nil, playedPercentage: Double? = nil) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: "Title \(id)", type: type)
        if logo { item.imageTags = ["Logo": "l"] }
        if backdrop { item.backdropImageTags = ["b"] }
        item.userData = UserItemData(playbackPositionTicks: resumeTicks, played: played, playedPercentage: playedPercentage)
        return item
    }

    private static func episode(of seriesId: String) -> JellyfinItem {
        var episode = JellyfinItem(id: "e.\(seriesId)", name: "Episode", type: "Episode")
        episode.seriesId = seriesId
        return episode
    }

    @Test func takesMoviesAndShowsInTurn() {
        let movies = ["m1", "m2", "m3", "m4"].map { Self.title($0) }
        let shows = ["s1", "s2"].map { Self.title($0, "Series") }
        let featured = HomeRows.featured(movies: movies, shows: shows, continueWatching: [])
        #expect(featured.map(\.id) == ["m1", "s1", "m2", "s2", "m3", "m4"])
    }

    @Test func leavesOutWhatsInContinueWatching() {
        let movies = [Self.title("m1"), Self.title("m2")]
        let shows = [Self.title("s1", "Series"), Self.title("s2", "Series")]
        let featured = HomeRows.featured(movies: movies, shows: shows, continueWatching: [movies[0], Self.episode(of: "s2")])
        #expect(featured.map(\.id) == ["m2", "s1"])
    }

    @Test func leavesOutWhatWasWatchedOrStarted() {
        let movies = [Self.title("watched", played: true), Self.title("started", resumeTicks: 600_000_000), Self.title("new")]
        let shows = [Self.title("begun", "Series", playedPercentage: 20), Self.title("fresh", "Series", playedPercentage: 0),
                     Self.title("done", "Series", played: true)]
        let featured = HomeRows.featured(movies: movies, shows: shows, continueWatching: [])
        #expect(featured.map(\.id) == ["new", "fresh"])
    }

    @Test func putsTitlesWithALogoFirstAndNeedsABackdrop() {
        let movies = [Self.title("plain", logo: false), Self.title("logo"), Self.title("bare", backdrop: false)]
        let featured = HomeRows.featured(movies: movies, shows: [], continueWatching: [])
        #expect(featured.map(\.id) == ["logo", "plain"])
    }

    @Test func fillsInWithTheBestRatedWhenThereAreTooFewNew() {
        let movies = [Self.title("m1"), Self.title("old", played: true)]
        let topRated = [Self.title("m1"), Self.title("t1"), Self.title("t2", "Series")]
        let featured = HomeRows.featured(movies: movies, shows: [], topRated: topRated, continueWatching: [])
        #expect(featured.map(\.id) == ["m1", "t1", "t2"])
    }

    @Test func featuresWhatWasWatchedOnlyWithNothingElse() {
        let movies = [Self.title("m1", played: true), Self.title("m2", played: true)]
        let featured = HomeRows.featured(movies: movies, shows: [], continueWatching: [Self.title("m2")])
        #expect(featured.map(\.id) == ["m1"])
    }

    @Test func featuresAtMostSix() {
        let movies = (0..<10).map { Self.title("m\($0)") }
        #expect(HomeRows.featured(movies: movies, shows: [], continueWatching: []).count == HomeRows.featuredCount)
    }
}

/// Rows Home leaves out, for repeating the rows above them or holding too little.
struct HomeCurationTests {
    private static func titles(_ ids: [String]) -> [JellyfinItem] {
        ids.map { JellyfinItem(id: $0, name: $0, type: "Movie") }
    }

    @Test func unwatchedFavoritesSameAsFavoritesGivesWay() {
        let favorites = Self.titles(["a", "b"])
        #expect(HomeRows.givesWay(HomeRows.unwatchedFavorites.id, titles: favorites, above: [favorites]))
        // With one of them watched, it's a row of its own.
        let unwatched = Self.titles(["b", "c"])
        #expect(!HomeRows.givesWay(HomeRows.unwatchedFavorites.id, titles: unwatched, above: [favorites]))
    }

    @Test func aRowMadeFromOneTitleOrGenreNeedsFourTitles() {
        let watched = JellyfinItem(id: "w", name: "Port Ellery", type: "Series")
        let because = HomeRows.becauseYouWatched(watched).id
        #expect(HomeRows.givesWay(because, titles: Self.titles(["x"]), above: []))
        #expect(HomeRows.givesWay(because, titles: Self.titles(["x", "y", "z"]), above: []))
        #expect(!HomeRows.givesWay(because, titles: Self.titles(["x", "y", "z", "q"]), above: []))
        #expect(HomeRows.givesWay(HomeRows.genre("Drama", type: "Movie").id, titles: Self.titles(["x", "y"]), above: []))
        #expect(HomeRows.givesWay(HomeRows.somethingDifferent("Drama").id, titles: Self.titles(["x"]), above: []))
        // A row of the newest, or the best, isn't made from one title.
        #expect(!HomeRows.givesWay(HomeRows.newMovies.id, titles: Self.titles(["x"]), above: []))
    }

    @Test func aRowMostlyAboveAlreadyGivesWay() {
        let recent = Self.titles((0..<12).map { "m\($0)" })
        // The same twelve, newest released first.
        let newReleases = Array(recent.reversed())
        #expect(HomeRows.givesWay(HomeRows.newMovies.id, titles: newReleases, above: [recent]))
        // Eight of its first ten above: a repeat.
        let mostly = Self.titles(["m0", "m1", "m2", "m3", "m4", "m5", "m6", "m7", "n1", "n2", "n3"])
        #expect(HomeRows.givesWay(HomeRows.topMovies.id, titles: mostly, above: [recent]))
        // Half of them new: a row worth having.
        let half = Self.titles(["m0", "n1", "m1", "n2", "m2", "n3", "m3", "n4", "m4", "n5"])
        #expect(!HomeRows.givesWay(HomeRows.topMovies.id, titles: half, above: [recent]))
    }

    @Test func rowsThatShowWhateverTheyHoldNeverGiveWay() {
        let recent = Self.titles(["a"])
        for id in [HomeRows.continueWatching.id, HomeRows.recentMovies.id, HomeRows.recentShows.id,
                   HomeRows.favorites.id, HomeRows.recentlyWatched.id] {
            #expect(!HomeRows.givesWay(id, titles: recent, above: [recent]))
        }
    }

    @Test func aRowHoldsOnlySomeOfItsListWhenItsFullOrTheListHasMore() {
        let twelve = Self.titles((0..<12).map { "m\($0)" })
        #expect(!HomeFeed.isTruncated(ItemsPage(items: twelve, totalRecordCount: 12)))
        #expect(HomeFeed.isTruncated(ItemsPage(items: twelve, totalRecordCount: 40)))
        // A list worked out whole, such as Continue Watching, as long as a row asks for.
        let full = Self.titles((0..<HomeRows.rowLength).map { "m\($0)" })
        #expect(HomeFeed.isTruncated(ItemsPage(items: full, totalRecordCount: full.count)))
    }
}

/// Home keeps its rows coming back to it.
struct HomeRefreshTests {
    @Test func keepsTheRowsComingBackSoon() {
        #expect(!HomeFeed.picksRows(reshuffling: false, awayFor: nil, isSettled: true))
        #expect(!HomeFeed.picksRows(reshuffling: false, awayFor: 29 * 60, isSettled: true))
    }

    @Test func picksTheRowsAgainAfterHalfAnHourAwayOrWhenPulled() {
        #expect(HomeFeed.picksRows(reshuffling: false, awayFor: 30 * 60, isSettled: true))
        #expect(HomeFeed.picksRows(reshuffling: true, awayFor: nil, isSettled: true))
    }

    @Test func picksTheRowsWhileTheyHaventLoaded() {
        #expect(HomeFeed.picksRows(reshuffling: false, awayFor: nil, isSettled: false))
    }
}

/// Taking titles out of Continue Watching, and putting them back.
struct ContinueWatchingRemovalTests {
    private static func movie(_ id: String, resumeTicks: Int64? = 600_000_000) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: "Movie \(id)", type: "Movie")
        item.userData = UserItemData(playbackPositionTicks: resumeTicks)
        return item
    }

    private static func episode(_ id: String, of seriesId: String, resumeTicks: Int64? = nil) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: "Episode \(id)", type: "Episode")
        item.seriesId = seriesId
        item.userData = UserItemData(playbackPositionTicks: resumeTicks)
        return item
    }

    @Test func aMovieHasItsPositionClearedOnEveryVersion() {
        var movie = Self.movie("m1")
        movie.mediaSources = [MediaSource(id: "m1"), MediaSource(id: "m1.4k")]
        let removal = ContinueWatchingRemoval(item: movie, position: 0, lastPlayed: nil)
        #expect(removal.clearing == ["m1", "m1.4k"])
        #expect(removal.hidingShow == nil)
    }

    @Test func anEpisodePartwayThroughIsClearedAndItsShowKeptOut() {
        let removal = ContinueWatchingRemoval(item: Self.episode("e3", of: "s1", resumeTicks: 600_000_000), position: 1, lastPlayed: nil)
        #expect(removal.clearing == ["e3"])
        #expect(removal.hidingShow == "s1")
    }

    @Test func aShowsNextEpisodeKeepsTheShowOutAlone() {
        let removal = ContinueWatchingRemoval(item: Self.episode("e4", of: "s1"), position: 0, lastPlayed: nil)
        #expect(removal.clearing.isEmpty)
        #expect(removal.hidingShow == "s1")
    }

    @Test func aTitleTakenOutStaysOutUntilSomethingOfItIsPlayedAgain() {
        let then = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let entries = [
            UpNext.Entry(item: Self.movie("m1"), lastPlayed: then),
            UpNext.Entry(item: Self.episode("e4", of: "s1"), lastPlayed: then),
            UpNext.Entry(item: Self.movie("m2"), lastPlayed: then),
        ]
        let takenOut = ["m1": then, "s1": then]
        #expect(HomeFeed.leavingOut(entries, takenOut: takenOut).map(\.item.id) == ["m2"])
        // Played again since: the show's next episode is back.
        let later = [UpNext.Entry(item: Self.episode("e5", of: "s1"), lastPlayed: then.addingTimeInterval(60))]
        #expect(HomeFeed.leavingOut(later, takenOut: takenOut).map(\.item.id) == ["e5"])
    }

    @Test func aShowKeptOutLeavesTheListUntilPlayedAfter() {
        let then = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var finished = Self.episode("e3", of: "s1")
        finished.userData = UserItemData(played: true, lastPlayedDate: JellyfinDate.format(then))
        var other = Self.episode("o1", of: "s2")
        other.userData = UserItemData(played: true, lastPlayedDate: JellyfinDate.format(then.addingTimeInterval(-60)))
        let shows = UpNext.shows(inProgress: [], finished: [finished, other], serverNext: [])
        var movie = Self.movie("m1")
        movie.userData?.lastPlayedDate = JellyfinDate.format(then.addingTimeInterval(-120))

        let titles = UpNext.titles(movies: [movie], shows: shows, hidden: ["s1": then])
        #expect(titles.count == 2)
        #expect(UpNext.returned(shows, marks: ["s1": then]).isEmpty)

        // An episode of it played after it was taken out brings it back.
        var again = Self.episode("e4", of: "s1")
        again.userData = UserItemData(played: true, lastPlayedDate: JellyfinDate.format(then.addingTimeInterval(300)))
        let played = UpNext.shows(inProgress: [], finished: [again, finished, other], serverNext: [])
        #expect(UpNext.titles(movies: [], shows: played, hidden: ["s1": then]).count == 2)
        #expect(UpNext.returned(played, marks: ["s1": then]) == ["s1"])
    }

    @Test func showsKeptOutAreRememberedByUserAndLetBack() throws {
        let suite = "ContinueWatchingRemovalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let then = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let hidden = UpNext.HiddenShows(userId: "u1", defaults: defaults)
        hidden.hide(seriesId: "s1", lastPlayed: then)
        hidden.hide(seriesId: "s2", lastPlayed: nil)
        #expect(hidden.marks == ["s1": then, "s2": .distantPast])
        #expect(UpNext.HiddenShows(userId: "u2", defaults: defaults).marks.isEmpty)

        hidden.letBack(["s1"])
        #expect(hidden.marks == ["s2": .distantPast])
    }

    @Test func keepsOutAtMostSoManyShowsLettingTheOldestBack() throws {
        let suite = "ContinueWatchingRemovalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hidden = UpNext.HiddenShows(userId: "u1", defaults: defaults)
        for index in 0...UpNext.HiddenShows.limit {
            hidden.hide(seriesId: "s\(index)", lastPlayed: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        #expect(hidden.marks.count == UpNext.HiddenShows.limit)
        #expect(hidden.marks["s0"] == nil)
    }
}

struct HeroTests {
    @Test func takesAtMostAShareOfAShortScreen() {
        #if os(tvOS)
        #expect(HeroBackdrop.height(820, visible: 1080) == 820)
        #else
        // An iPhone held upright, then sideways.
        #expect(HeroBackdrop.height(440, visible: 874) == 440)
        #expect(HeroBackdrop.height(440, visible: 402) == 241)
        // Before the screen is measured.
        #expect(HeroBackdrop.height(440, visible: 0) == 440)
        #endif
    }

    @Test func factsEndWithAsManyGenresAsFit() {
        var movie = JellyfinItem(id: "m", name: "Movie", type: "Movie")
        movie.productionYear = 2024
        movie.officialRating = "PG-13"
        movie.communityRating = 7.8
        movie.genres = ["Science Fiction", "Drama", "Mystery", "Thriller"]
        #expect(FactsLine.facts(for: movie, genres: 1).map(\.text) == ["2024", "PG-13", "★ 7.8", "Science Fiction"])
        let wide = FactsLine.facts(for: movie, genres: 3)
        #expect(wide.map(\.text) == ["2024", "PG-13", "★ 7.8", "Science Fiction", "Drama", "Mystery"])
        #expect(wide.map(\.isGenre) == [false, false, false, true, true, true])
    }
}

struct ArtworkTests {
    @Test func loadsAgainOnlyWhatTheServerMightSendNextTime() {
        func loading(_ failure: any Error) -> ImagePipeline.Error { .dataLoadingFailed(error: failure) }
        #expect(Artwork.isWorthRetrying(loading(URLError(.timedOut))))
        #expect(Artwork.isWorthRetrying(loading(URLError(.notConnectedToInternet))))
        #expect(Artwork.isWorthRetrying(loading(DataLoader.Error.statusCodeUnacceptable(503))))
        #expect(Artwork.isWorthRetrying(loading(DataLoader.Error.statusCodeUnacceptable(429))))
        #expect(!Artwork.isWorthRetrying(loading(DataLoader.Error.statusCodeUnacceptable(404))))
        #expect(!Artwork.isWorthRetrying(loading(DataLoader.Error.statusCodeUnacceptable(401))))
        #expect(!Artwork.isWorthRetrying(loading(URLError(.cancelled))))
        #expect(!Artwork.isWorthRetrying(ImagePipeline.Error.dataIsEmpty))
        #expect(!Artwork.isWorthRetrying(ImagePipeline.Error.imageRequestMissing))
        #expect(!Artwork.isWorthRetrying(ImagePipeline.Error.cancelled))
        let context = ImageDecodingContext(request: ImageRequest(url: nil), data: Data())
        #expect(Artwork.isWorthRetrying(ImagePipeline.Error.decodingFailed(decoder: ImageDecoders.Empty(), context: context, error: IncompleteImage())))
        #expect(!Artwork.isWorthRetrying(ImagePipeline.Error.decodingFailed(decoder: ImageDecoders.Empty(), context: context, error: ImageDecodingError.unknown)))
    }

    /// A picture of noise, which compresses poorly, so its file is a good deal bigger than the
    /// cut-off download that was found cached: 24,576 bytes of an 80,629-byte logo.
    private static func noise(as type: String) throws -> Data {
        let size = 256
        var random = SeededRandom(seed: 3)
        var pixels = (0..<size * size * 4).map { _ in UInt8.random(in: 0...255, using: &random) }
        let image = try #require(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func aPictureCutOffPartwayIsIncomplete() throws {
        let png = try Self.noise(as: "public.png")
        #expect(png.count > 24_576)
        #expect(ImageData.isComplete(png))
        #expect(!ImageData.isComplete(png.prefix(24_576)))
        let jpeg = try Self.noise(as: "public.jpeg")
        #expect(ImageData.isComplete(jpeg))
        #expect(!ImageData.isComplete(jpeg.prefix(jpeg.count / 2)))
        #expect(!ImageData.isComplete(Data()))
    }

    @Test func theDecoderTurnsDownAPictureCutOffPartway() throws {
        let png = try Self.noise(as: "public.png")
        let context = ImageDecodingContext(request: ImageRequest(url: nil), data: png)
        let decoder = try #require(ImageDecoderRegistry.shared.decoder(for: context))
        let complete = CompleteImageDecoder(base: decoder, request: context.request)
        #expect(throws: IncompleteImage.self) { try complete.decode(png.prefix(24_576)) }
        #expect(throws: Never.self) { try complete.decode(png) }
    }

    @Test func waitsLongerEachTimeUpToHalfAMinute() {
        #expect((1...7).map(Artwork.delay(beforeRetry:)) == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(Artwork.delay(beforeRetry: 5000) == .seconds(30))
    }
}
