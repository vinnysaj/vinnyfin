import Foundation
import SwiftUI
import Testing
@testable import vinnyfin

/// A title page's hero and actions: what Play says and plays on a show's page, the season it opens
/// on, Shuffle's order, the version chip, the episode's still, and marking many episodes at once,
/// which asks first for a whole show or season and can be undone.
struct TitlePageTests {
    private static let now = JellyfinDate.parse("2026-11-14T12:00:00Z")!

    private static func episode(_ id: String, season: Int? = 1, _ number: Int, played: Bool = false, position: Int64 = 0,
                                playCount: Int? = nil, lastPlayed: String? = nil, premiere: String? = nil) -> JellyfinItem {
        var episode = JellyfinItem(id: id, name: "Episode \(number)", type: "Episode")
        episode.seriesId = "show"
        episode.seriesName = "Port Ellery"
        episode.seasonId = season.map { "season\($0)" }
        episode.parentIndexNumber = season
        episode.indexNumber = number
        episode.premiereDate = premiere
        episode.runTimeTicks = 52 * 60 * 10_000_000
        episode.userData = UserItemData(playbackPositionTicks: position, playCount: playCount, played: played, lastPlayedDate: lastPlayed)
        return episode
    }

    private static func season(_ number: Int) -> JellyfinItem {
        var season = JellyfinItem(id: "season\(number)", name: number == 0 ? "Specials" : "Season \(number)", type: "Season")
        season.indexNumber = number
        season.seriesId = "show"
        season.seriesName = "Port Ellery"
        return season
    }

    // MARK: Play on a show's page

    @Test func playNamesTheEpisodeAloneInTheFirstSeason() {
        #expect(ShowPlayback.playLabel(for: Self.episode("e1", 1), seasons: 2) == "Play Episode 1")
        #expect(ShowPlayback.spokenPlayLabel(for: Self.episode("e1", 1), seasons: 2) == "Play Episode 1")
        let resumed = Self.episode("e2", 2, position: 21 * 60 * 10_000_000)
        #expect(ShowPlayback.playLabel(for: resumed, seasons: 2) == "Resume Episode 2 · 31 min left")
        #expect(ShowPlayback.spokenPlayLabel(for: resumed, seasons: 2) == "Resume Episode 2, 31 minutes left")
    }

    @Test func playNamesTheSeasonPastTheFirst() {
        #expect(ShowPlayback.playLabel(for: Self.episode("e7", season: 2, 1), seasons: 2) == "Play S2, E1")
        #expect(ShowPlayback.spokenPlayLabel(for: Self.episode("e7", season: 2, 1), seasons: 2) == "Play Season 2, Episode 1")
        // A show of one season, numbered by its year, needs no season either.
        #expect(ShowPlayback.playLabel(for: Self.episode("y3", season: 2024, 3), seasons: 1) == "Play Episode 3")
    }

    @Test func playNamesADoubleEpisodeAndASpecial() {
        var double = Self.episode("e2", 2)
        double.indexNumberEnd = 3
        #expect(ShowPlayback.playLabel(for: double, seasons: 1) == "Play Episodes 2–3")
        #expect(ShowPlayback.spokenPlayLabel(for: double, seasons: 1) == "Play Episodes 2 to 3")
        #expect(ShowPlayback.playLabel(for: Self.episode("sp", season: 0, 1), seasons: 1) == "Play Specials, E1")
        // Without a number, its name.
        var unnumbered = Self.episode("x", 1)
        unnumbered.indexNumber = nil
        #expect(ShowPlayback.playLabel(for: unnumbered, seasons: 1) == "Play Episode 1")
    }

    @Test func aShowsMenuSaysWhatKindOfPlayItIs() {
        var show = JellyfinItem(id: "show", name: "Port Ellery", type: "Series")
        #expect(ShowPlayback.menuTitle(for: show) == "Play")
        show.userData = UserItemData(played: false, playedPercentage: 16.7)
        #expect(ShowPlayback.menuTitle(for: show) == "Play Next Episode")
        show.userData = UserItemData(played: true)
        #expect(ShowPlayback.menuTitle(for: show) == "Watch Again")
    }

    // MARK: The season a show's page opens on

    @Test func opensOnTheSeasonAskedForThenTheNextEpisodesThenTheLastWatched() {
        let seasons = [Self.season(0), Self.season(1), Self.season(2)]
        let next = Self.episode("e3", season: 2, 3)
        let last = Self.episode("e2", season: 1, 2, played: true)
        #expect(ShowPlayback.initialSeason(in: seasons, requested: "season1", next: next, lastWatched: last) == "season1")
        #expect(ShowPlayback.initialSeason(in: seasons, requested: nil, next: next, lastWatched: last) == "season2")
        // A season asked for that the show doesn't have gives way.
        #expect(ShowPlayback.initialSeason(in: seasons, requested: "gone", next: next, lastWatched: nil) == "season2")
    }

    @Test func opensAfterAFinaleOnTheSeasonOfTheFinale() {
        let seasons = [Self.season(1), Self.season(2)]
        let finale = Self.episode("e12", season: 2, 6, played: true)
        #expect(ShowPlayback.initialSeason(in: seasons, requested: nil, next: nil, lastWatched: finale) == "season2")
    }

    @Test func opensANewShowOnItsFirstSeasonPastTheSpecials() {
        let seasons = [Self.season(0), Self.season(1), Self.season(2)]
        #expect(ShowPlayback.initialSeason(in: seasons, requested: nil, next: nil, lastWatched: nil) == "season1")
        #expect(ShowPlayback.initialSeason(in: [Self.season(0)], requested: nil, next: nil, lastWatched: nil) == "season0")
        #expect(ShowPlayback.initialSeason(in: [], requested: "season1", next: nil, lastWatched: nil) == "season1")
    }

    // MARK: Shuffle

    @Test func aShuffleHoldsItsOrderForItsSeedAndTakesEveryEpisodeOnce() {
        let episodes = (1...12).map { Self.episode("e\($0)", $0 <= 6 ? 1 : 2) }
        let order = PlayOrder.shuffled(episodes, seed: 42, now: Self.now)
        #expect(order == PlayOrder.shuffled(episodes, seed: 42, now: Self.now))
        #expect(order.ids.sorted() == episodes.map(\.id).sorted())
        #expect(order.ids != episodes.map(\.id))
        #expect(PlayOrder.shuffled(episodes, seed: 43, now: Self.now) != order)
    }

    @Test func aShuffleLeavesOutSpecialsAndWhatIsntOut() {
        let episodes = [Self.episode("e1", 1), Self.episode("sp", season: 0, 1), Self.episode("e2", 2),
                        Self.episode("later", 3, premiere: "2027-01-01T00:00:00Z")]
        #expect(PlayOrder.shuffled(episodes, seed: 7, now: Self.now).ids.sorted() == ["e1", "e2"])
    }

    @Test func anOrdersNextAndPreviousGoByItsOrderAndStopAtItsEnds() {
        let order = PlayOrder(ids: ["e5", "e1", "e9"])
        #expect(order.id(after: "e5") == "e1")
        #expect(order.id(after: "e1") == "e9")
        #expect(order.id(after: "e9") == nil)
        #expect(order.id(before: "e9") == "e1")
        #expect(order.id(before: "e5") == nil)
        #expect(Array(order.ids(after: "e5")) == ["e1", "e9"])
        // An episode not in it has neither.
        #expect(order.id(after: "e2") == nil)
        #expect(order.id(before: "e2") == nil)
        #expect(!order.contains("e2"))
    }

    @Test func aRequestKeepsItsOrderWhenSavedAndPlayedAgain() throws {
        var request = PlaybackRequest.item(Self.episode("e1", 1))
        request.order = PlayOrder(ids: ["e1", "e3", "e2"])
        let saved = try JSONDecoder().decode(PlaybackRequest.self, from: JSONEncoder().encode(request))
        #expect(saved.order == request.order)
        #expect(request.replaying(from: 0, title: "Episode 1").order == request.order)
        // A request saved before orders were kept still opens.
        let older = try JSONDecoder().decode(PlaybackRequest.self, from: Data(#"""
            {"id":"9E2D7C2E-6A8B-4F0C-9C1D-2B3A4C5D6E7F","source":{"item":{"id":"e1"}},"title":"Episode 1","startFromBeginning":false}
            """#.utf8))
        #expect(older.order == nil)
    }

    // MARK: Marking many episodes, and Undo

    @Test func aShowOrSeasonMarksManyEpisodesAndAsksFirst() {
        #expect(WatchActions.marksManyEpisodes(JellyfinItem(id: "s", name: "Port Ellery", type: "Series")))
        #expect(WatchActions.marksManyEpisodes(Self.season(1)))
        #expect(!WatchActions.marksManyEpisodes(Self.episode("e1", 1)))
        #expect(!WatchActions.marksManyEpisodes(Samples.movie))
    }

    @Test func theQuestionSaysHowManyEpisodesItMarks() {
        let show = JellyfinItem(id: "s", name: "Port Ellery", type: "Series")
        let watched = WatchChangeWording(item: show, played: true, episodes: 12)
        #expect(watched.question == "Mark Port Ellery as Watched?")
        #expect(watched.consequence == "All 12 episodes will be marked as watched.")
        #expect(watched.action == "Mark as Watched")
        #expect(watched.done == "Marked as Watched")
        #expect(watched.subject == "Port Ellery")

        let season = WatchChangeWording(item: Self.season(2), played: false, episodes: 6)
        #expect(season.question == "Mark Season 2 as Unwatched?")
        #expect(season.consequence == "All 6 episodes of Season 2 of Port Ellery will be marked as unwatched.")
        #expect(season.action == "Mark as Unwatched")
        #expect(season.subject == "Port Ellery · Season 2")

        #expect(WatchChangeWording(item: show, played: true, episodes: 1).consequence == "Its one episode will be marked as watched.")
        #expect(WatchChangeWording(item: show, played: true, episodes: nil).consequence == "Every episode will be marked as watched.")
        #expect(WatchChangeWording.done(played: true, count: 3) == "Marked 3 Episodes as Watched")
        #expect(WatchChangeWording.done(played: false, count: 1) == "Marked 1 Episode as Unwatched")
    }

    @Test func undoPutsEachEpisodeBackAsItWas() {
        let snapshot = WatchSnapshot([
            Self.episode("watched", 1, played: true, playCount: 6, lastPlayed: "2026-11-14T23:08:06.9808263Z"),
            Self.episode("partway", 2, position: 18_009_829_836, playCount: 3, lastPlayed: "2026-11-14T23:42:54.7369035Z"),
            Self.episode("begun", 3, playCount: 2, lastPlayed: "2026-11-14T22:36:07.4888192Z"),
            Self.episode("untouched", 4),
        ])
        var watched = UserDataUpdate(positionTicks: 0, played: true, lastPlayed: nil)
        watched.LastPlayedDate = "2026-11-14T23:08:06.9808263Z"
        watched.PlayCount = 6
        var partway = UserDataUpdate(positionTicks: 18_009_829_836, played: false, lastPlayed: nil)
        partway.LastPlayedDate = "2026-11-14T23:42:54.7369035Z"
        partway.PlayCount = 3
        var begun = UserDataUpdate(positionTicks: 0, played: false, lastPlayed: nil)
        begun.LastPlayedDate = "2026-11-14T22:36:07.4888192Z"
        begun.PlayCount = 2
        // Marked watched, every one changed; one never played goes back to unwatched, which dates nothing.
        #expect(snapshot.restoring(afterMarking: true) == [
            .userData("watched", watched), .userData("partway", partway), .userData("begun", begun), .unwatched("untouched"),
        ])
        // Marked unwatched, one never played had nothing to lose.
        #expect(snapshot.restoring(afterMarking: false) == [
            .userData("watched", watched), .userData("partway", partway), .userData("begun", begun),
        ])
    }

    @Test func aRestoreSendsEveryPartOfTheWatchState() throws {
        let data = UserItemData(playbackPositionTicks: 5, playCount: 2, played: false, lastPlayedDate: "2026-11-14T22:36:07.4888192Z")
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(UserDataUpdate(restoring: data))) as? [String: Any])
        #expect(body["PlaybackPositionTicks"] as? Int == 5)
        #expect(body["Played"] as? Bool == false)
        #expect(body["PlayCount"] as? Int == 2)
        #expect(body["LastPlayedDate"] as? String == "2026-11-14T22:36:07.4888192Z")
    }

    @Test func markPreviousTakesTheEpisodesBeforeNotYetWatched() {
        let episodes = [Self.episode("sp", season: 0, 1), Self.episode("e1", 1, played: true), Self.episode("e2", 2),
                        Self.episode("e3", 3, position: 10), Self.episode("e4", 4), Self.episode("e5", 5)]
        #expect(WatchSnapshot.previous(before: episodes[4], in: episodes, now: Self.now).map(\.id) == ["e2", "e3"])
        #expect(WatchSnapshot.previous(before: episodes[1], in: episodes, now: Self.now).isEmpty)
        #expect(WatchSnapshot.previous(before: Self.episode("elsewhere", 9), in: episodes, now: Self.now).isEmpty)
    }

    @MainActor
    @Test func anUndoOfferedIsTakenOnceAndGivesWayToTheNext() {
        let messages = AppMessages()
        var undone: [String] = []
        var expired: [String] = []
        let first = UndoOffer(title: "Marked as Watched", detail: "Port Ellery", announcement: "") { undone.append("first") } expire: {
            expired.append("first")
        }
        messages.offerUndo(first)
        let second = UndoOffer(title: "Marked as Watched", detail: "The Long Field", announcement: "") { undone.append("second") } expire: {
            expired.append("second")
        }
        messages.offerUndo(second)
        // The first stands once the next is offered.
        #expect(expired == ["first"])
        messages.undo(first.id)
        #expect(undone.isEmpty)
        messages.undo(second.id)
        messages.undo(second.id)
        #expect(undone == ["second"])
        #expect(messages.undoOffer == nil)
        messages.expireUndo(second.id)
        #expect(expired == ["first"])
    }

    // MARK: The version chip

    private static func source(_ id: String, name: String?, width: Int? = nil, height: Int? = nil, range: String? = nil,
                               size: Int64? = nil) -> MediaSource {
        var source = MediaSource(id: id, name: name)
        if let width, let height {
            var video = MediaStream(type: "Video")
            video.width = width
            video.height = height
            video.videoRangeType = range
            source.mediaStreams = [video]
        }
        source.size = size
        return source
    }

    @Test func versionsAreCalledByTheirPicture() {
        let sources = [Self.source("a", name: "2160p", width: 3840, height: 2160, range: "SDR", size: 40_451_055),
                       Self.source("b", name: "1080p", width: 1920, height: 1080, range: "SDR", size: 19_102_886)]
        let names = VersionNames(sources)
        #expect(names.name(sources[0]) == "4K")
        #expect(names.name(sources[1]) == "1080p")
        #expect(names.title(of: sources[0]) == "4K · \(Int64(40_451_055).formatted(.byteCount(style: .file)))")
        #expect(VersionNames.plainName(Self.source("d", name: "Remux", width: 3840, height: 2160, range: "DOVIWithHDR10")) == "4K Dolby Vision")
        #expect(VersionNames.plainName(Self.source("h", name: nil, width: 1920, height: 800, range: "HDR10")) == "1080p HDR")
    }

    @Test func versionsCalledTheSameAreToldApartByTheirNames() {
        let sources = [Self.source("a", name: "Theatrical", width: 1920, height: 1080),
                       Self.source("b", name: "Director's Cut", width: 1920, height: 1080),
                       Self.source("c", name: nil, width: 1920, height: 1080)]
        let names = VersionNames(sources)
        #expect(names.name(sources[0]) == "1080p · Theatrical")
        #expect(names.name(sources[1]) == "1080p · Director's Cut")
        #expect(names.name(sources[2]) == "1080p · 3")
        // Nothing of the picture known: the server's name, or failing that, "Version".
        #expect(VersionNames.plainName(Self.source("r", name: "Stream")) == "Stream")
        #expect(VersionNames.plainName(Self.source("x", name: "Default")) == "Version")
    }

    @Test func theMenuLeavesTheSizeOutOfWhatsInAVersion() {
        var source = Self.source("a", name: "1080p", width: 1920, height: 1080, size: 300_000_000)
        source.container = "mkv"
        #expect(!source.detailLine(withSize: false).contains("MB"))
        #expect(source.detailLine.contains("MB"))
    }

    // MARK: The episode's still

    @MainActor
    @Test func anEpisodesStillIsTheHeroWhenItsSharpEnough() {
        #expect(DetailHero<EmptyView>.usesStill(width: 1920))
        #expect(DetailHero<EmptyView>.usesStill(width: 1280))
        #expect(!DetailHero<EmptyView>.usesStill(width: 640))
        #expect(!DetailHero<EmptyView>.usesStill(width: nil))
    }
}
