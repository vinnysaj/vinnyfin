import Foundation
import Testing
@testable import vinnyfin

private let client = JellyfinClient(serverURL: URL(string: "https://jf.example.com")!, deviceId: "d", deviceName: "iPhone", token: "tok")

/// A movie in two versions, its own ("m") with three chapters, the second without a picture, and
/// scrub previews of the other version ("v").
private func movieWithChapters() -> JellyfinItem {
    var movie = JellyfinItem(id: "m", name: "The Quiet Meridian", type: "Movie")
    movie.runTimeTicks = 3_600 * 10_000_000
    var own = MediaSource(id: "m", name: "2160p")
    own.runTimeTicks = 3_600 * 10_000_000
    var other = MediaSource(id: "v", name: "1080p")
    other.runTimeTicks = 3_000 * 10_000_000
    movie.mediaSources = [own, other]
    movie.chapters = [
        Chapter(startPositionTicks: 0, name: "The Survey Office", imageTag: "t0"),
        Chapter(startPositionTicks: 1_020 * 10_000_000, name: " ", imageTag: nil),
        Chapter(startPositionTicks: 2_160 * 10_000_000, name: "The Moved Markers", imageTag: "t2"),
    ]
    let previews = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 360, interval: 10_000)
    movie.trickplay = ["v": ["320": previews]]
    return movie
}

struct ScenesTests {
    @Test func picturesAChaptersStartFromTheVersionsOwnChapters() throws {
        let movie = movieWithChapters()
        let scenes = TitleScenes.streaming(movie, versionItem: movie, client: client)
        #expect(scenes.chapters.map(\.name) == ["The Survey Office", "Chapter 2", "The Moved Markers"])
        let width = TitleScenes.imageWidth
        #expect(scenes.chapters[0].image?.absoluteString
            == "https://jf.example.com/Items/m/Images/Chapter/0?maxWidth=\(width)&quality=90&tag=t0")
        #expect(scenes.chapters[1].image == nil)
        #expect(scenes.chapters[2].image?.absoluteString
            == "https://jf.example.com/Items/m/Images/Chapter/2?maxWidth=\(width)&quality=90&tag=t2")
        // The own version has no previews, so a chapter without a picture has neither.
        #expect(scenes.previews == nil)
        #expect(scenes.length == 3_600)
    }

    @Test func anotherVersionsScenesAreItsOwnItemsChaptersWithItsPreviews() throws {
        let movie = movieWithChapters()
        var version = JellyfinItem(id: "v", name: "The Quiet Meridian", type: "Movie")
        version.chapters = [
            Chapter(startPositionTicks: 0, name: "The Survey Office", imageTag: "u0"),
            Chapter(startPositionTicks: 900 * 10_000_000, name: "Up the Pass", imageTag: nil),
        ]
        let scenes = TitleScenes.streaming(movie, versionItem: version, client: client)
        #expect(scenes.chapters.map(\.start) == [0, 900])
        #expect(scenes.chapters[0].image?.absoluteString.hasPrefix("https://jf.example.com/Items/v/Images/Chapter/0?") == true)
        let previews = try #require(scenes.previews)
        #expect(previews.sheets.first?.absoluteString == "https://jf.example.com/Videos/m/Trickplay/320/0.jpg?ApiKey=tok&mediaSourceId=v")
        // The version's own length, which its last chapter runs to.
        #expect(scenes.length == 3_000)
        #expect(scenes.end(of: scenes.chapters[1]) == 3_000)
    }

    @Test func aDownloadsScenesHaveItsSavedPicturesAndPreviews() throws {
        var saved = movieWithChapters()
        saved.mediaSources = [MediaSource(id: "v", name: "1080p")]
        let picture = URL(filePath: "/tmp/Chapters/0-t0.jpg")
        let sheet = URL(filePath: "/tmp/Trickplay/320/0.jpg")
        let copy = PlaybackResolver.DownloadedCopy(url: URL(filePath: "/tmp/m.mkv"), item: saved, segments: [],
                                                   trickplaySheets: [0: sheet, 1: sheet, 2: sheet, 3: sheet], chapterImages: [0: picture])
        let scenes = TitleScenes.downloaded(copy, client: client)
        #expect(scenes.chapters[0].image == picture)
        // Not saved yet: the server's picture of the downloaded version.
        #expect(scenes.chapters[2].image?.absoluteString.hasPrefix("https://jf.example.com/Items/v/Images/Chapter/2?") == true)
        #expect(scenes.previews?.sheets.first == sheet)
        #expect(TitleScenes.downloaded(copy, client: nil).chapters[2].image == nil)
    }

    @Test func aPreviewStandsForAChapterFromAMomentIn() {
        let scenes = TitleScenes.streaming(movieWithChapters(), versionItem: movieWithChapters(), client: client)
        #expect(scenes.previewTime(of: scenes.chapters[0]) == 15)
        #expect(scenes.previewTime(of: scenes.chapters[1]) == 1_035)
        let short = TitleScenes(chapters: [ChapterMark(index: 0, start: 0, name: "Cold Open", image: nil)], length: 60)
        #expect(short.previewTime(of: short.chapters[0]) == 6)
    }

    @Test func showsHowFarIntoItsChapterAResumeStarts() {
        let scenes = TitleScenes.streaming(movieWithChapters(), versionItem: movieWithChapters(), client: client)
        #expect(scenes.progress(of: scenes.chapters[1], resumingAt: 1_590) == 0.5)
        #expect(scenes.progress(of: scenes.chapters[0], resumingAt: 1_590) == nil)
        #expect(scenes.progress(of: scenes.chapters[1], resumingAt: nil) == nil)
        #expect(scenes.progress(of: scenes.chapters[2], resumingAt: 2_880) == 0.5)
    }

    @Test func startsAtTheChapterWhateverTheResumePosition() throws {
        let movie = movieWithChapters()
        let chapter = TitleScenes.streaming(movie, versionItem: movie, client: client).chapters[1]
        let request = TitleScenes.request(playing: movie, from: chapter, mediaSourceId: nil)
        #expect(request.source == .item(id: "m", mediaSourceId: nil))
        #expect(request.startingPoint == PlaybackRequest.StartingPoint(position: 1_020))
        #expect(request.start(resuming: 300) == 1_020)
        #expect(request.start(resuming: 3_000) == 1_020)
        #expect(!request.resumesSavedPosition(300))
        #expect(!request.startFromBeginning)
        // The page's details, chapters and versions and all, which the player starts from.
        #expect(request.loadedItem == movie)

        let picked = TitleScenes.request(playing: movie, from: chapter, mediaSourceId: "v")
        #expect(picked.source == .item(id: "m", mediaSourceId: "v"))
        // The first chapter starts at the start, past any resume position.
        let first = TitleScenes.request(playing: movie, from: TitleScenes.streaming(movie, versionItem: movie, client: client).chapters[0],
                                        mediaSourceId: nil)
        #expect(first.start(resuming: 300) == 0)

        // As the Mac's player window gets it.
        let decoded = try JSONDecoder().decode(PlaybackRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.startingPoint?.position == 1_020)
    }

    @Test func saysWhenAChapterStarts() {
        #expect(TitleScenes.timeText(0) == "0:00")
        #expect(TitleScenes.timeText(1_020) == "17:00")
        #expect(TitleScenes.timeText(3_735.6) == "1:02:15")
        #expect(TitleScenes.spokenTime(0) == "From the start")
        #expect(TitleScenes.spokenTime(1_020) == "From 17 minutes in")
    }
}

struct CreditsTests {
    private func person(_ id: String, _ type: String, role: String? = nil) -> Person {
        Person(id: id, name: "Person \(id)", role: role, type: type)
    }

    @Test func listsTheCastThenCreatorsDirectorsAndWritersEachOnce() {
        let credits = Credits(people: [
            person("a", "Actor", role: "Ada"),
            person("w", "Writer", role: "Screenplay"),
            person("d", "Writer", role: "Story"),
            person("b", "GuestStar", role: "Bea"),
            person("d", "Director"),
            person("p", "Producer"),
            person("a", "Actor", role: "Ada's Twin"),
            person("c", "Creator"),
            person("a", "Director"),
            person("x", "Actor"),
        ])
        #expect(credits.cast.map(\.person.id) == ["a", "b", "x"])
        #expect(credits.cast.map(\.detail) == ["Ada / Ada's Twin", "Bea", nil])
        #expect(credits.crew.map(\.person.id) == ["c", "d", "a", "w"])
        #expect(credits.crew.map(\.detail) == ["Creator", "Director, Writer", "Director", "Writer"])
        // An actor who directed is in the cast and the crew, each with an id of its own.
        #expect(credits.listed.map(\.id) == ["cast.a", "cast.b", "cast.x", "crew.c", "crew.d", "crew.a", "crew.w"])
        #expect(credits.people(doing: "Director").map(\.id) == ["d", "a"])
        #expect(credits.people(doing: "Writer").map(\.id) == ["d", "w"])
    }

    @Test func listsTheLeadingCastAheadOfTheCrewOfALongCast() {
        let actors = (1...30).map { person("a\($0)", "Actor") }
        let credits = Credits(people: actors + [person("d", "Director")])
        #expect(credits.cast.count == 30)
        #expect(credits.listed.map(\.id) == (1...Credits.listedCast).map { "cast.a\($0)" } + ["crew.d"])
    }

    @Test func hasNothingForATitleWithoutPeople() {
        #expect(Credits(people: []).isEmpty)
        #expect(Credits(people: [person("p", "Producer")]).isEmpty)
    }
}

struct FilmographyTests {
    private func item(_ id: String, _ type: String, show: String? = nil, season: Int? = nil, episode: Int? = nil) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: id, type: type)
        item.seriesId = show
        item.parentIndexNumber = season
        item.indexNumber = episode
        return item
    }

    @Test func groupsTheEpisodesOfShowsTheyGuestOnByShow() {
        // As the server lists them, the newest first.
        let filmography = Filmography(credits: [
            item("m1", "Movie"),
            item("port-3", "Episode", show: "port", season: 1, episode: 3),
            item("long", "Series"),
            item("long-1", "Episode", show: "long", season: 1, episode: 1),
            item("star-5", "Episode", show: "star", season: 2, episode: 5),
            item("port-1", "Episode", show: "port", season: 1, episode: 1),
            item("star-2", "Episode", show: "star", season: 1, episode: 2),
            item("m2", "Movie"),
        ])
        #expect(filmography.movies.map(\.id) == ["m1", "m2"])
        #expect(filmography.shows.map(\.id) == ["long"])
        // A show they're credited on as a whole isn't listed by episode too.
        #expect(filmography.episodes.map(\.id) == ["port-1", "port-3", "star-2", "star-5"])
        #expect(!filmography.isEmpty)
        #expect(Filmography(credits: []).isEmpty)
    }

    @Test func asksForEpisodesAsWellAsMoviesAndShows() {
        let query = Filmography.query(personId: "p")
        #expect(Set(query.types) == ["Movie", "Series", "Episode"])
        #expect(query.personIds == ["p"])
        #expect(query.sortBy == "PremiereDate")
        #expect(!query.ascending)
    }

    @Test func saysWhenAndWhereSomeoneWasBornAndDied() {
        var person = JellyfinItem(id: "p", name: "Ada Vale", type: "Person")
        #expect(PersonLife.lines(of: person).isEmpty)
        person.premiereDate = "1972-05-02T00:00:00.0000000Z"
        person.productionLocations = ["Kingston, Jamaica"]
        #expect(PersonLife.lines(of: person) == ["Born May 2, 1972 in Kingston, Jamaica"])
        person.endDate = "2020-06-01T00:00:00.0000000Z"
        #expect(PersonLife.lines(of: person) == ["Born May 2, 1972 in Kingston, Jamaica", "Died June 1, 2020"])
        person.premiereDate = nil
        #expect(PersonLife.lines(of: person) == ["Born in Kingston, Jamaica", "Died June 1, 2020"])
    }
}

struct EndTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func movie(minutes: Int64?, resumeSeconds: Int64? = nil, played: Bool = false) -> JellyfinItem {
        var movie = JellyfinItem(id: "m", name: "Movie", type: "Movie")
        movie.runTimeTicks = minutes.map { $0 * 60 * 10_000_000 }
        movie.userData = UserItemData(playbackPositionTicks: (resumeSeconds ?? 0) * 10_000_000, played: played)
        return movie
    }

    @Test func endsAfterTheWholeTitleFromTheStart() {
        #expect(EndTime.end(of: movie(minutes: 120), now: now) == now.addingTimeInterval(7_200))
        // Watched, with no position, it plays from the start.
        #expect(EndTime.end(of: movie(minutes: 120, played: true), now: now) == now.addingTimeInterval(7_200))
    }

    @Test func endsAfterWhatsLeftFromWhereResumeStarts() {
        // Resume starts a few seconds before the position.
        #expect(EndTime.end(of: movie(minutes: 120, resumeSeconds: 1_800), now: now)
            == now.addingTimeInterval(7_200 - 1_800 + PlaybackRequest.resumeLeadIn))
    }

    @Test func hasNoEndWithoutALengthOrAFileToPlay() {
        #expect(EndTime.end(of: movie(minutes: nil), now: now) == nil)
        var show = JellyfinItem(id: "s", name: "Show", type: "Series")
        show.runTimeTicks = 3_000 * 10_000_000
        #expect(EndTime.end(of: show, now: now) == nil)
        var upcoming = movie(minutes: 100)
        upcoming.locationType = "Virtual"
        #expect(EndTime.end(of: upcoming, now: now) == nil)
    }

    @Test func listsTheEndAmongTheFacts() {
        var title = movie(minutes: 128)
        title.premiereDate = "2025-05-14T00:00:00.0000000Z"
        title.officialRating = "PG-13"
        let facts = TitleFacts.facts(for: title, source: nil, credits: Credits(people: []), now: now)
        let ends = EndTime.text(now.addingTimeInterval(128 * 60))
        #expect(facts.map(\.label) == ["Released", "Run Time", "Ends At", "Rated"])
        #expect(facts.map(\.value) == ["May 14, 2025", "2h 8m", ends, "PG-13"])
        #expect(!TitleFacts.facts(for: title, source: nil, credits: Credits(people: []), now: nil).map(\.label).contains("Ends At"))
    }

    @Test func listsWhoMadeItWhereAndInWhichLanguages() {
        var title = movie(minutes: 90)
        title.studios = [NamedItem(name: "Northlight"), NamedItem(name: "Harbor Films")]
        var source = MediaSource(id: "m")
        var english = MediaStream(type: "Audio")
        english.language = "eng"
        var french = MediaStream(type: "Audio")
        french.language = "fre"
        var subtitles = MediaStream(type: "Subtitle")
        subtitles.language = "eng"
        var unknown = MediaStream(type: "Subtitle")
        unknown.language = "und"
        source.mediaStreams = [english, french, english, subtitles, unknown]
        let credits = Credits(people: [Person(id: "d", name: "Ada Vale", type: "Director"), Person(id: "w", name: "Bo Lind", type: "Writer")])
        let facts = Dictionary(uniqueKeysWithValues: TitleFacts.facts(for: title, source: source, credits: credits, now: nil).map { ($0.label, $0.value) })
        #expect(facts["Studios"] == "Northlight and Harbor Films")
        #expect(facts["Directed By"] == "Ada Vale")
        #expect(facts["Written By"] == "Bo Lind")
        #expect(facts["Audio"] == ["eng", "fre"].map(AppSettings.displayName).formatted(.list(type: .and)))
        #expect(facts["Subtitles"] == AppSettings.displayName(for: "eng"))
    }

    @Test func saysWhenAShowAiredAndWhetherItGoesOn() {
        var show = JellyfinItem(id: "s", name: "Show", type: "Series")
        show.premiereDate = "2019-09-01T00:00:00.0000000Z"
        show.status = "Ended"
        show.endDate = "2023-03-01T00:00:00.0000000Z"
        #expect(TitleFacts.airedYears(of: show) == "2019–2023")
        #expect(TitleFacts.status(of: show) == "Ended")
        show.endDate = nil
        show.status = "Continuing"
        #expect(TitleFacts.airedYears(of: show) == "2019–Present")
        show.studios = [NamedItem(name: "Harbor TV")]
        let labels = TitleFacts.facts(for: show, source: nil, credits: Credits(people: []), now: Date()).map(\.label)
        #expect(labels == ["Aired", "Status", "Network"])
    }
}

struct ExtrasTests {
    @Test func readsTrailersExtrasAndStudiosFromTheDetails() throws {
        let json = """
        {"Id": "m", "Name": "Movie", "Type": "Movie", "LocalTrailerCount": 1, "SpecialFeatureCount": 2,
         "RemoteTrailers": [{"Url": "https://www.youtube.com/watch?v=abc", "Name": "Official Trailer"}],
         "Studios": [{"Name": "Northlight", "Id": "s1"}], "EndDate": "2023-03-01T00:00:00.0000000Z",
         "ProductionLocations": ["Kingston, Jamaica"]}
        """
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        #expect(item.localTrailerCount == 1)
        #expect(item.specialFeatureCount == 2)
        #expect(item.remoteTrailers == [RemoteTrailer(url: "https://www.youtube.com/watch?v=abc", name: "Official Trailer")])
        #expect(item.studios == [NamedItem(name: "Northlight", id: "s1")])
        #expect(item.endDate == "2023-03-01T00:00:00.0000000Z")
        #expect(item.productionLocations == ["Kingston, Jamaica"])
        // Kept with a download as it came.
        #expect(try JSONDecoder().decode(JellyfinItem.self, from: JSONEncoder().encode(item)) == item)

        let extra = try JSONDecoder().decode(JellyfinItem.self, from: Data("""
            {"Id": "x", "Name": "Making the Meridian", "Type": "Video", "ExtraType": "BehindTheScenes", "RunTimeTicks": 7200000000}
            """.utf8))
        #expect(extra.extraType == "BehindTheScenes")
        #expect(TitleExtra.video(extra).detail == "Behind the Scenes · 12m")
    }

    @Test func listsTrailersFirstThenExtrasByKind() {
        var movie = JellyfinItem(id: "m", name: "Movie", type: "Movie")
        movie.remoteTrailers = [
            RemoteTrailer(url: "https://www.youtube.com/watch?v=abc", name: "Official Trailer"),
            RemoteTrailer(url: "https://www.youtube.com/watch?v=abc", name: "Official Trailer"),
            RemoteTrailer(url: "plugin://trailers/abc", name: "Not a page"),
            RemoteTrailer(url: "https://vimeo.com/123", name: ""),
        ]
        func extra(_ id: String, _ type: String?) -> JellyfinItem {
            var item = JellyfinItem(id: id, name: id, type: "Video")
            item.extraType = type
            return item
        }
        let trailer = extra("t", "Trailer")
        let features = [extra("deleted", "DeletedScene"), extra("odd", nil), extra("bts", "BehindTheScenes"), extra("talk", "Interview")]
        let list = TitleExtra.list(of: movie, trailers: [trailer], features: features, opensWeb: true)
        #expect(list.map(\.id) == ["t", "https://www.youtube.com/watch?v=abc", "https://vimeo.com/123", "bts", "talk", "deleted", "odd"])
        #expect(list.map(\.name) == ["t", "Official Trailer", "Trailer", "bts", "talk", "deleted", "odd"])
        #expect(list[1].detail == "Trailer · YouTube")
        #expect(list[2].detail == "Trailer · Vimeo")
        #expect(list[6].detail == "Extra")
        // Apple TV has no browser to open the web's in.
        #expect(TitleExtra.list(of: movie, trailers: [trailer], features: [], opensWeb: false).map(\.id) == ["t"])
    }

    @Test func hasTheRowOnlyForATitleWithSomething() {
        var movie = JellyfinItem(id: "m", name: "Movie", type: "Movie")
        #expect(!TitleExtra.mayHave(movie, opensWeb: true))
        movie.remoteTrailers = [RemoteTrailer(url: "https://www.youtube.com/watch?v=abc")]
        #expect(TitleExtra.mayHave(movie, opensWeb: true))
        #expect(!TitleExtra.mayHave(movie, opensWeb: false))
        movie.specialFeatureCount = 1
        #expect(TitleExtra.mayHave(movie, opensWeb: false))
    }
}

/// More Like This and the chips, from a server that answers at a host of its own, so only these
/// tests reach it.
struct RelatedTitlesTests {
    @Test func fillsAnEmptyMoreLikeThisFromTheFirstGenreThatHasOthers() async throws {
        var movie = JellyfinItem(id: "lonely-1", name: "Signal Over Kestrel Bay", type: "Movie")
        movie.genres = ["Western", "Thriller"]
        let related = try await RelatedTitles.load(for: movie, client: RelatedTitlesStub.client, userId: "u", length: 16)
        #expect(related.similar.map(\.name) == ["Neon Tidewater"])
        #expect(related.similarList == BrowseList.genre("Thriller", excluding: "lonely-1"))
        #expect(related.genres == ["Western", "Thriller"])
        // A server without the collections lookup has the title in none.
        #expect(related.collections.isEmpty)
        let asked = RelatedTitlesStub.requests(mentioning: "lonely-1").filter { $0.path() == "/Items" }
        #expect(asked.map { $0.query(named: "genres") } == ["Western", "Thriller"])
        #expect(asked.allSatisfy { $0.query(named: "excludeItemIds") == "lonely-1" })
    }

    @Test func keepsTheServersSimilarTitlesAndTheirSeeAll() async throws {
        var movie = JellyfinItem(id: "similar-boxed-1", name: "The Quiet Meridian", type: "Movie")
        movie.genres = ["Drama"]
        let related = try await RelatedTitles.load(for: movie, client: RelatedTitlesStub.client, userId: "u", length: 16)
        #expect(related.similar.map(\.id) == ["like-similar-boxed-1"])
        #expect(related.similarList == .moreLike(movie))
        #expect(related.collections.map(\.name) == ["The Meridian Collection"])
        #expect(!RelatedTitlesStub.requests(mentioning: "similar-boxed-1").contains { $0.path() == "/Items" })
    }

    @Test func takesAnEpisodesGenresAndCollectionsFromItsShow() async throws {
        var episode = JellyfinItem(id: "episode-1", name: "Dead Reckoning", type: "Episode")
        episode.seriesId = "show-1"
        let related = try await RelatedTitles.load(for: episode, client: RelatedTitlesStub.client, userId: "u", length: 16)
        #expect(related.titleId == "show-1")
        #expect(related.genres == ["Thriller"])
        #expect(related.genres(of: episode) == ["Thriller"])
        #expect(related.similar.map(\.name) == ["Neon Tidewater"])
        #expect(related.similarList == BrowseList.genre("Thriller", excluding: "show-1"))
        var other = episode
        other.seriesId = "show-2"
        #expect(related.genres(of: other).isEmpty)
    }

    @Test func leavesMoreLikeThisEmptyWhenNoGenreHasOthers() async throws {
        var movie = JellyfinItem(id: "only-1", name: "Copperline", type: "Movie")
        movie.genres = ["Western"]
        let related = try await RelatedTitles.load(for: movie, client: RelatedTitlesStub.client, userId: "u", length: 16)
        #expect(related.similar.isEmpty)
        #expect(related.similarList == nil)
    }
}

/// A server for `RelatedTitlesTests`: it finds titles like those whose ids start "similar-", has
/// those whose ids hold "boxed-" in a collection and answers 404 for the rest, as a server without
/// the lookup does, gives every show the genre Thriller, and has one Thriller, Neon Tidewater.
nonisolated final class RelatedTitlesStub: URLProtocol {
    private static let host = "related-titles.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [URL] = []
    private static let registered: Void = { URLProtocol.registerClass(RelatedTitlesStub.self) }()

    static var client: JellyfinClient {
        _ = registered
        return JellyfinClient(serverURL: URL(string: "https://\(host)")!, deviceId: "d", deviceName: "iPhone", token: "tok")
    }

    /// The requests whose address has `text` in it.
    static func requests(mentioning text: String) -> [URL] {
        lock.withLock { asked.filter { $0.absoluteString.contains(text) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.asked.append(url) }
        let (status, body) = Self.answer(to: url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(to url: URL) -> (Int, String) {
        let parts = url.path().split(separator: "/").map(String.init)
        func page(_ items: String...) -> String { "{\"Items\": [\(items.joined(separator: ","))]}" }
        if parts.count == 3, parts[0] == "Items", parts[2] == "Similar" {
            let id = parts[1]
            return (200, id.hasPrefix("similar-") ? page("{\"Id\": \"like-\(id)\", \"Name\": \"Like It\", \"Type\": \"Movie\"}") : page())
        }
        if parts.count == 3, parts[0] == "Items", parts[2] == "Collections" {
            guard parts[1].contains("boxed-") else { return (404, "") }
            return (200, page("{\"Id\": \"box\", \"Name\": \"The Meridian Collection\", \"Type\": \"BoxSet\"}"))
        }
        guard parts == ["Items"] else { return (404, "") }
        if url.query(named: "includeItemTypes") == "Series" {
            let id = url.query(named: "ids") ?? ""
            return (200, page("{\"Id\": \"\(id)\", \"Name\": \"Show\", \"Type\": \"Series\", \"Genres\": [\"Thriller\"]}"))
        }
        guard url.query(named: "genres") == "Thriller" else { return (200, page()) }
        return (200, page("{\"Id\": \"thriller-1\", \"Name\": \"Neon Tidewater\", \"Type\": \"Movie\"}"))
    }
}

nonisolated private extension URL {
    func query(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
