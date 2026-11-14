import Foundation
import SwiftUI
import Testing
@testable import vinnyfin

private func freshDefaults() -> UserDefaults {
    let name = "shell-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

struct CellularStreamingQualityTests {
    @Test func streamsAt720pOnCellularUnlessChosenOtherwise() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.cellularStreamingQuality == .hd)
        #expect(settings.streamingQuality(on: .unmetered) == .original)
        #expect(settings.streamingQuality(on: .expensive) == .hd)
    }

    @Test func lowDataModeKeepsToTheCellularQualityOnAnyNetwork() {
        let settings = AppSettings(defaults: freshDefaults())
        // Low Data Mode on Wi-Fi.
        let lowDataWiFi = StreamingNetwork(isExpensive: false, isConstrained: true)
        #expect(lowDataWiFi == .lowData)
        #expect(settings.streamingQuality(on: lowDataWiFi) == .hd)
        // On cellular with Low Data Mode too.
        #expect(StreamingNetwork(isExpensive: true, isConstrained: true) == .lowData)
        #expect(StreamingNetwork(isExpensive: true, isConstrained: false) == .expensive)
        #expect(StreamingNetwork(isExpensive: false, isConstrained: false) == .unmetered)
        #expect(!StreamingNetwork.unmetered.savesData)
        #expect(StreamingNetwork.expensive.savesData && StreamingNetwork.lowData.savesData)
    }

    @Test func neverStreamsMoreOnCellularThanAtHome() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.streamingQuality = .sd
        settings.cellularStreamingQuality = .fullHD
        #expect(settings.streamingQuality(on: .expensive) == .sd)
        // Best Available on cellular leaves streams to the streaming quality.
        settings.streamingQuality = .fullHD
        settings.cellularStreamingQuality = .original
        #expect(settings.streamingQuality(on: .lowData) == .fullHD)
        settings.cellularStreamingQuality = .sd
        #expect(settings.streamingQuality(on: .expensive) == .sd)
        #expect(settings.streamingQuality(on: .unmetered) == .fullHD)
    }

    @Test func theChoiceIsKeptOnThisDevice() {
        let defaults = freshDefaults()
        AppSettings(defaults: defaults).cellularStreamingQuality = .sd
        #expect(AppSettings(defaults: defaults).cellularStreamingQuality == .sd)
        #expect(!AppSettings.syncs("settings.cellularStreamingQuality"))
    }

    @Test func aRetiredSettingIsDeletedRatherThanSentToICloud() {
        let defaults = freshDefaults()
        defaults.set(7, forKey: "settings.smartDownloadCount")
        _ = AppSettings(defaults: defaults)
        #expect(defaults.object(forKey: "settings.smartDownloadCount") == nil)
    }
}

struct LinkRoutingTests {
    private let title = Samples.movie

    @Test func opensOnTheTabOnScreenAfterWhatItShows() {
        for tab in [MainTabs.Destination.home, .movies, .shows, .downloads, .search] {
            var navigation = TabNavigation()
            navigation.selection = tab
            navigation.movies.append(Samples.episode)
            navigation.open(title)
            #expect(navigation.selection == tab)
            let paths = [MainTabs.Destination.home: navigation.home, .movies: navigation.movies, .shows: navigation.shows,
                         .downloads: navigation.downloads, .search: navigation.search]
            for (other, path) in paths {
                // The page Movies already showed stays, a page back.
                let before = other == .movies ? 1 : 0
                #expect(path.count == before + (other == tab ? 1 : 0), "\(tab), \(other)")
            }
        }
    }

    @Test func aTabWithoutTitlesGivesWayToHome() {
        for tab in [MainTabs.Destination.settings, .sounds] {
            var navigation = TabNavigation()
            navigation.home.append(Samples.episode)
            navigation.selection = tab
            navigation.open(title)
            #expect(navigation.selection == .home)
            #expect(navigation.home.count == 2)
        }
    }

    @Test func linksFollowedOneAfterAnotherStack() {
        var navigation = TabNavigation()
        navigation.selection = .shows
        navigation.open(title)
        navigation.open(Samples.episode)
        #expect(navigation.shows.count == 2)
        #expect(navigation.home.isEmpty)
    }
}

#if !os(tvOS)
struct DownloadGroupsTests {
    private static func episode(_ id: String, show: String, seriesId: String?, season: Int, number: Int) -> DownloadJob {
        let series = seriesId.map { #","SeriesId":"\#($0)""# } ?? ""
        let item = Samples.item(#"{"Id":"\#(id)","Name":"Episode \#(number)","Type":"Episode","SeriesName":"\#(show)"\#(series),"ParentIndexNumber":\#(season),"IndexNumber":\#(number)}"#)
        var job = DownloadJob(item: item, source: Samples.source)
        job.totalBytes = 100
        return job
    }

    private static func movie(_ id: String, _ name: String) -> DownloadJob {
        DownloadJob(item: Samples.item(#"{"Id":"\#(id)","Name":"\#(name)","Type":"Movie"}"#), source: Samples.source)
    }

    @Test func groupsEpisodesByShowInOrderAfterTheMovies() {
        let jobs = [
            Self.episode("b2", show: "Port Ellery", seriesId: "pe", season: 1, number: 2),
            Self.movie("m2", "Copperline"),
            Self.episode("a1", show: "Amber Show", seriesId: "as", season: 2, number: 1),
            Self.episode("b1", show: "Port Ellery", seriesId: "pe", season: 1, number: 1),
            Self.episode("b9", show: "Port Ellery", seriesId: "pe", season: 0, number: 9),
            Self.movie("m1", "Amber Cartographers"),
        ]
        let groups = DownloadGroups(finished: jobs, rules: [])
        #expect(groups.movies.map(\.itemId) == ["m1", "m2"])
        #expect(groups.shows.map(\.name) == ["Amber Show", "Port Ellery"])
        let portEllery = groups.shows[1]
        #expect(portEllery.id == "pe")
        #expect(portEllery.seriesId == "pe")
        // Specials, season 0, first; then season by season.
        #expect(portEllery.episodes.map(\.itemId) == ["b9", "b1", "b2"])
        #expect(portEllery.bytes == 300)
        #expect(portEllery.rule == nil)
    }

    @Test func aShowKeptDownloadedHasItsGroupWithOrWithoutEpisodes() {
        let jobs = [Self.episode("b1", show: "Port Ellery", seriesId: "pe", season: 1, number: 1)]
        let rules = [SmartDownloads.Rule(seriesId: "pe", seriesName: "Port Ellery", episodesAhead: 3),
                     SmartDownloads.Rule(seriesId: "sk", seriesName: "Small Kitchens", episodesAhead: nil)]
        let groups = DownloadGroups(finished: jobs, rules: rules)
        #expect(groups.shows.map(\.name) == ["Port Ellery", "Small Kitchens"])
        #expect(groups.shows[0].rule?.episodesAhead == 3)
        #expect(groups.shows[0].episodes.count == 1)
        #expect(groups.shows[1].rule != nil && groups.shows[1].rule?.episodesAhead == nil)
        #expect(groups.shows[1].episodes.isEmpty)
    }

    @Test func anEpisodeSavedWithoutItsShowsIdGroupsByName() {
        let jobs = [Self.episode("x1", show: "Old Show", seriesId: nil, season: 1, number: 1),
                    Self.episode("x2", show: "Old Show", seriesId: nil, season: 1, number: 2)]
        let groups = DownloadGroups(finished: jobs, rules: [])
        #expect(groups.shows.count == 1)
        #expect(groups.shows[0].id == "Old Show")
        #expect(groups.shows[0].seriesId == nil)
    }

    @Test func notesTheWatchedEpisodesDeletedFromEachShowForAWeek() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = Self.episode("b1", show: "Port Ellery", seriesId: "pe", season: 1, number: 1)
        let second = Self.episode("b2", show: "Port Ellery", seriesId: "pe", season: 1, number: 2)
        let other = Self.episode("a1", show: "Amber Show", seriesId: "as", season: 1, number: 1)
        var removals = WatchedRemoval.adding([first], to: [:], at: start)
        #expect(removals["pe"]?.episodes == ["S01E01"])
        // Deletions that run on are told of together.
        removals = WatchedRemoval.adding([second, other], to: removals, at: start.addingTimeInterval(3600))
        #expect(removals["pe"]?.episodes == ["S01E01", "S01E02"])
        #expect(removals["pe"]?.bytes == 200)
        #expect(removals["pe"]?.date == start.addingTimeInterval(3600))
        #expect(removals["as"]?.episodes == ["S01E01"])
        #expect(removals["pe"]?.isRecent(at: start.addingTimeInterval(6 * 24 * 3600)) == true)
        // A week on, they're no longer told of, and the next deletion starts afresh.
        let later = start.addingTimeInterval(9 * 24 * 3600)
        #expect(removals["pe"]?.isRecent(at: later) == false)
        removals = WatchedRemoval.adding([Self.episode("b3", show: "Port Ellery", seriesId: "pe", season: 1, number: 3)],
                                         to: removals, at: later)
        #expect(removals["pe"]?.episodes == ["S01E03"])
        #expect(removals["as"] == nil)
    }

    @Test func offersTheCountAShowIsKeptWithAmongTheMenusChoices() {
        #expect(SmartDownloadCounts.counts(keeping: nil) == [3, 5, 10, 20])
        #expect(SmartDownloadCounts.counts(keeping: 10) == [3, 5, 10, 20])
        #expect(SmartDownloadCounts.counts(keeping: 7) == [3, 5, 7, 10, 20])
    }
}
#endif
