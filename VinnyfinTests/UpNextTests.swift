import Foundation
import Testing
@testable import vinnyfin

/// What's next: one entry per movie or show, the episode to go on with, the latest first.
struct UpNextTests {
    private static let now = JellyfinDate.parse("2026-11-14T12:00:00Z")!

    private static func episode(_ id: String, show: String = "s1", season: Int = 1, _ number: Int, played: Bool = false,
                                position: Int64 = 0, lastPlayed: String? = nil, premiere: String? = nil,
                                location: String? = nil) -> JellyfinItem {
        var episode = JellyfinItem(id: id, name: "Episode \(number)", type: "Episode")
        episode.seriesId = show
        episode.parentIndexNumber = season
        episode.indexNumber = number
        episode.premiereDate = premiere
        episode.locationType = location
        episode.userData = UserItemData(playbackPositionTicks: position, played: played, lastPlayedDate: lastPlayed)
        return episode
    }

    private static func movie(_ id: String, lastPlayed: String?) -> JellyfinItem {
        var movie = JellyfinItem(id: id, name: id, type: "Movie")
        movie.userData = UserItemData(playbackPositionTicks: 600_000_000, lastPlayedDate: lastPlayed)
        return movie
    }

    @Test func goesOnWithTheEpisodePartwayThroughWhenItWasPlayedLast() {
        let show = UpNext.Show(seriesId: "s1",
                               inProgress: Self.episode("e5", 5, position: 1, lastPlayed: "2026-11-13T20:00:00Z"),
                               finished: Self.episode("e4", 4, played: true, lastPlayed: "2026-11-13T19:00:00Z"),
                               serverNext: Self.episode("e6", 6))
        #expect(UpNext.pick(for: show, now: Self.now) == .episode(show.inProgress!))
    }

    @Test func leavesAnEpisodeAbandonedBeforeLaterOnesWereFinished() {
        let show = UpNext.Show(seriesId: "s1",
                               inProgress: Self.episode("e3", 3, position: 1, lastPlayed: "2026-10-01T20:00:00Z"),
                               finished: Self.episode("e6", 6, played: true, lastPlayed: "2026-11-13T19:00:00Z"),
                               serverNext: Self.episode("e7", 7))
        #expect(UpNext.pick(for: show, now: Self.now) == .episode(show.serverNext!))
    }

    @Test func takesTheServersNextOnlyWhenItFollowsTheEpisodeFinishedLast() {
        let finished = Self.episode("e2", season: 2, 3, played: true, lastPlayed: "2026-11-13T19:00:00Z")
        // A later episode marked watched by mistake moved the server's next past it.
        let show = UpNext.Show(seriesId: "s1", finished: finished, serverNext: Self.episode("x", season: 5, 2))
        #expect(UpNext.pick(for: show, now: Self.now) == .after(finished))
    }

    @Test func aDoubleEpisodeIsFollowedByTheOneAfterItsLastNumber() {
        var double = Self.episode("e1", 1, played: true, lastPlayed: "2026-11-13T19:00:00Z")
        double.indexNumberEnd = 2
        let show = UpNext.Show(seriesId: "s1", finished: double, serverNext: Self.episode("e3", 3))
        #expect(UpNext.pick(for: show, now: Self.now) == .episode(show.serverNext!))
    }

    @Test func findsTheFirstEpisodeToWatchAfterTheOneFinishedLast() {
        let finished = Self.episode("e3", 3, played: true)
        let following = [
            finished,
            Self.episode("e4", 4, played: true),
            Self.episode("sp", season: 0, 1),
            Self.episode("e5", 5, location: "Virtual"),
            Self.episode("e6", 6),
            Self.episode("e7", 7),
        ]
        #expect(UpNext.firstToWatch(after: finished, in: following, now: Self.now)?.id == "e6")
    }

    @Test func anEpisodeNotYetAiredIsntNext() {
        let unaired = Self.episode("e9", 9, premiere: "2026-11-20T00:00:00.0000000Z")
        #expect(!UpNext.isAvailable(unaired, now: Self.now))
        #expect(UpNext.isAvailable(Self.episode("e8", 8, premiere: "2026-11-14T00:00:00Z"), now: Self.now))
        let finished = Self.episode("e8", 8, played: true, lastPlayed: "2026-11-13T19:00:00Z")
        let show = UpNext.Show(seriesId: "s1", finished: finished, serverNext: unaired)
        #expect(UpNext.pick(for: show, now: Self.now) == .after(finished))
        #expect(UpNext.firstToWatch(after: finished, in: [finished, unaired], now: Self.now) == nil)
    }

    @Test func aShowNothingOfHasBeenWatchedStartsWithTheServersPick() {
        let first = Self.episode("e1", 1)
        #expect(UpNext.pick(for: UpNext.Show(seriesId: "s1", serverNext: first), now: Self.now) == .episode(first))
        #expect(UpNext.pick(for: UpNext.Show(seriesId: "s1"), now: Self.now) == .nothing)
    }

    @Test func gathersEachShowOnceFromTheThreeLists() {
        let shows = UpNext.shows(
            inProgress: [Self.episode("a5", show: "a", 5, position: 1), Self.movie("m", lastPlayed: nil), Self.episode("a2", show: "a", 2, position: 1)],
            finished: [Self.episode("b3", show: "b", 3, played: true), Self.episode("a4", show: "a", 4, played: true)],
            serverNext: [Self.episode("c1", show: "c", 1), Self.episode("b4", show: "b", 4)]
        )
        #expect(shows.map(\.seriesId) == ["a", "b", "c"])
        #expect(shows[0].inProgress?.id == "a5")
        #expect(shows[0].finished?.id == "a4")
        #expect(shows[1].serverNext?.id == "b4")
        #expect(shows[2].finished == nil)
    }

    @Test func putsTheTitlePlayedLastFirstAndShowsTheHistoryDoesntReachLast() {
        let movie = Self.movie("m", lastPlayed: "2026-11-12T20:00:00Z")
        let recent = UpNext.Show(seriesId: "a", finished: Self.episode("a1", show: "a", 1, played: true, lastPlayed: "2026-11-13T20:00:00Z"))
        let older = UpNext.Show(seriesId: "b", inProgress: Self.episode("b1", show: "b", 1, position: 1, lastPlayed: "2026-11-01T20:00:00Z"))
        let unknown = UpNext.Show(seriesId: "c", serverNext: Self.episode("c1", show: "c", 1))
        let titles = UpNext.titles(movies: [movie], shows: [unknown, older, recent])
        #expect(titles == [.show(recent), .movie(movie), .show(older), .show(unknown)])
    }
}
