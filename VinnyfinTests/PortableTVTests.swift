import Foundation
import Testing
@testable import vinnyfin

private func general(_ json: String) throws -> RemoteCommand? {
    RemoteCommand(try SocketMessage(json: Data(#"{"MessageType":"GeneralCommand","Data":\#(json)}"#.utf8)))
}

struct TVPressTests {
    @Test func everyPressComesBackAsSent() {
        let presses: [TVPress] = [
            .up, .down, .left, .right, .select, .back, .home(nil), .home(.library), .home(.youTube), .text("lofi hip hop"),
            .point(x: 0.25, y: 0.75), .click(x: 0.5, y: 0.125), .scroll(dx: -12, dy: 340), .fullScreen,
        ]
        for press in presses {
            #expect(TVPress(press.command) == press)
        }
    }

    @Test func readsTheMovesAsJellyfinsRemotesSendThem() throws {
        // As Jellyfin's web app sends its remote's presses, with the controlling user.
        #expect(try general(#"{"Name":"MoveUp","ControllingUserId":"fabef5b2fd88436d8cf985ebfd35bce9","Arguments":{}}"#) == .tv(.up))
        #expect(try general(#"{"Name":"MoveRight"}"#) == .tv(.right))
        #expect(try general(#"{"Name":"Select"}"#) == .tv(.select))
        #expect(try general(#"{"Name":"Back"}"#) == .tv(.back))
        #expect(try general(#"{"Name":"GoHome"}"#) == .tv(.home(nil)))
        #expect(try general(#"{"Name":"SendString","Arguments":{"String":"dune"}}"#) == .tv(.text("dune")))
    }

    @Test func homeItDoesntKnowIsHomeOfWhatShows() throws {
        #expect(try general(#"{"Name":"GoHome","Arguments":{"Home":"YouTube"}}"#) == .tv(.home(.youTube)))
        #expect(try general(#"{"Name":"GoHome","Arguments":{"Home":"Netflix"}}"#) == .tv(.home(nil)))
    }

    @Test func leavesOutPressesItCantRead() throws {
        #expect(try general(#"{"Name":"SendString"}"#) == nil)
        #expect(try general(#"{"Name":"SendKey","Arguments":{"Key":"Enter"}}"#) == nil)
        #expect(try general(#"{"Name":"SendKey","Arguments":{"Key":"Pointer","X":"0.5"}}"#) == nil)
        #expect(try general(#"{"Name":"SendKey","Arguments":{"Key":"Click","X":"nan","Y":"0.5"}}"#) == nil)
        #expect(try general(#"{"Name":"ToggleOsd"}"#) == nil)
    }

    @Test func sendsThePointerShortAndInAnyLanguage() {
        let command = TVPress.point(x: 0.123456789, y: 1).command
        #expect(command.name == "SendKey")
        #expect(command.arguments == ["Key": "Pointer", "X": "0.12346", "Y": "1"])
        #expect(TVPress.scroll(dx: -1234.5, dy: 0).command.arguments["X"] == "-1234.5")
    }

    @Test func aTVSaysWhichPressesItTakesWhereItIs() throws {
        func commands(_ capabilities: ClientCapabilities) throws -> [String] {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(capabilities)) as? [String: Any]
            return json?["SupportedCommands"] as? [String] ?? []
        }
        let standard = try commands(ClientCapabilities())
        let library = try commands(.portableTV(showing: .library))
        let youTube = try commands(.portableTV(showing: .youTube))
        #expect(Array(library.prefix(standard.count)) == standard)
        #expect(library.contains("MoveUp") && library.contains("Select") && !library.contains("SendKey"))
        #expect(youTube.contains("SendKey") && youTube.contains("Select") && !youTube.contains("MoveUp"))
        #expect(!standard.contains("Select"))
    }
}

struct TelevisionTests {
    private func session(_ id: String, client: String = "vinnyfin macOS", name: String, deviceId: String? = nil,
                         commands: [String]) -> RemoteSession {
        RemoteSession(id: id, client: client, deviceName: name, deviceId: deviceId ?? "device-\(id)",
                      supportedCommands: commands)
    }

    private let library = TVPress.commands(in: .library).map(\.rawValue)
    private let youTube = TVPress.commands(in: .youTube).map(\.rawValue)

    @Test func listsWhatTakesPressesVinnyfinFirst() {
        let sessions = [
            session("web", client: "Jellyfin Web", name: "Firefox", commands: library + ["SendKey", "ToggleOsd"]),
            session("tv", name: "Studio", commands: youTube),
            session("mac", name: "MacBook", commands: library),
            session("phone", client: "vinnyfin iOS", name: "iPhone", commands: ["SetAudioStreamIndex", "Play"]),
            session("self", name: "This Mac", deviceId: "me", commands: library),
        ]
        let televisions = PlayTarget.televisions(from: sessions, excludingDeviceId: "me")
        #expect(televisions.map(\.id) == ["mac", "tv", "web"])
    }

    @Test func readsWhatAVinnyfinTVShows() {
        let televisions = PlayTarget.televisions(from: [
            session("mac", name: "A", commands: library),
            session("tv", name: "B", commands: youTube),
            session("web", client: "Jellyfin Web", name: "C", commands: library + ["SendKey"]),
        ], excludingDeviceId: "me")
        #expect(televisions.map(\.tvSpace) == [.library, .youTube, .library])
        #expect(televisions.map(\.hasYouTube) == [true, true, false])
    }
}

/// Moves focus, saying whether it moved: `#expect` can't wrap a mutating call.
private func step(_ focus: inout TVFocus, _ direction: TVDirection, _ rows: [TVRow]) -> Bool {
    focus.move(direction, in: rows)
}

struct TVFocusTests {
    private let rows = [TVRow(id: "a", count: 3), TVRow(id: "empty", count: 0), TVRow(id: "b", count: 2)]

    @Test func startsOnTheFirstItemOfTheFirstRowWithAny() {
        let focus = TVFocus()
        #expect(focus.focused(in: [TVRow(id: "loading", count: 0)] + rows)?.row.id == "a")
        #expect(focus.focused(in: [TVRow(id: "loading", count: 0)]) == nil)
    }

    @Test func movesAlongARowAndStopsAtItsEnds() {
        var focus = TVFocus()
        #expect(!step(&focus, .left, rows))
        #expect(step(&focus, .right, rows))
        #expect(step(&focus, .right, rows))
        #expect(!step(&focus, .right, rows))
        #expect(focus.isFocused(row: "a", column: 2, in: rows))
    }

    @Test func passesOverEmptyRowsAndSaysWhenItCantGoUp() {
        var focus = TVFocus()
        #expect(!step(&focus, .up, rows))
        #expect(step(&focus, .down, rows))
        #expect(focus.focused(in: rows)?.row.id == "b")
        #expect(!step(&focus, .down, rows))
    }

    @Test func comesBackToWhereEachRowWasLeft() {
        var focus = TVFocus()
        _ = focus.move(.right, in: rows)
        _ = focus.move(.right, in: rows)
        _ = focus.move(.down, in: rows)
        _ = focus.move(.right, in: rows)
        _ = focus.move(.up, in: rows)
        #expect(focus.isFocused(row: "a", column: 2, in: rows))
        _ = focus.move(.down, in: rows)
        #expect(focus.isFocused(row: "b", column: 1, in: rows))
    }

    @Test func keepsToARowThatShrank() {
        var focus = TVFocus()
        _ = focus.move(.right, in: rows)
        _ = focus.move(.right, in: rows)
        let shrunk = [TVRow(id: "a", count: 1)]
        #expect(focus.focused(in: shrunk)?.column == 0)
        #expect(!step(&focus, .left, shrunk))
    }

    @Test func movesOnFromTheFirstRowWhenItsRowIsGone() {
        var focus = TVFocus()
        _ = focus.move(.down, in: rows)
        let reloaded = [TVRow(id: "c", count: 4), TVRow(id: "a", count: 3)]
        #expect(focus.focused(in: reloaded)?.row.id == "c")
        // From where focus shows, so the press does what it looks like it will.
        #expect(step(&focus, .down, reloaded))
        #expect(focus.focused(in: reloaded)?.row.id == "a")
    }
}

#if os(macOS)
struct YouTubeTVTests {
    @Test func staysOnYouTube() throws {
        func allows(_ string: String) throws -> Bool { YouTubeTV.allows(try #require(URL(string: string))) }
        #expect(try allows("https://www.youtube.com/watch?v=abc"))
        #expect(try allows("https://m.youtube.com/"))
        #expect(try allows("https://youtu.be/abc"))
        #expect(try allows("https://accounts.google.com/ServiceLogin"))
        #expect(try allows("https://consent.youtube.com/m"))
        #expect(try !allows("https://www.google.com/search?q=anything"))
        #expect(try !allows("https://example.com/"))
        #expect(try !allows("https://notyoutube.com/"))
        #expect(try !allows("https://youtube.com.example.com/"))
        #expect(try !allows("http://www.youtube.com/"))
    }
}

struct TVPageTests {
    private func item(_ json: String) -> JellyfinItem { Samples.item(json) }

    @Test func playsAMovieFromWhereItWasLeftOrFromTheBeginning() {
        let movie = item(#"{"Id":"m","Name":"Dune","Type":"Movie","RunTimeTicks":60000000000,"UserData":{"PlaybackPositionTicks":6000000000}}"#)
        let page = TVPage(picked: movie)
        #expect(page.actions == [.play, .restart])
        guard case .play(let resume) = page.select() else {
            Issue.record("Select didn't play")
            return
        }
        #expect(!resume.startFromBeginning)
        _ = page.move(.right)
        guard case .play(let restart) = page.select() else {
            Issue.record("Select didn't play")
            return
        }
        #expect(restart.startFromBeginning)
    }

    @Test func anEpisodeOpensItsShowReadyToPlayIt() {
        let episode = item(#"{"Id":"e","Name":"Pilot","Type":"Episode","SeriesId":"s","SeasonId":"s1"}"#)
        let page = TVPage(picked: episode)
        #expect(page.isShow)
        #expect(page.next?.id == "e")
        #expect(page.seasonId == "s1")
        #expect(page.actions == [.play])
    }
}
#endif
