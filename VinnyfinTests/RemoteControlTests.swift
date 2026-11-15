import AetherEngine
import Foundation
import Testing
@testable import vinnyfin

/// The socket's messages as a Jellyfin 12.4 server sent them, their message ids shortened.
private enum Captured {
    static let forceKeepAlive = #"{"MessageId":"6a3c1e0f9b2d4c7e8f1a2b3c4d5e6f70","Data":60,"MessageType":"ForceKeepAlive"}"#
    static let keepAlive = #"{"MessageId":"0f1e2d3c4b5a69788796a5b4c3d2e1f0","MessageType":"KeepAlive"}"#
    static let play = #"""
    {"MessageId":"1b2c3d4e5f60718293a4b5c6d7e8f901","Data":{"ItemIds":["2b60d7fcb1c30c67852b1bb4241b50e8","ae9a7f9f8184f53f5e92514b2f57e336","9c969a5e049d6f20ea68bd6c67fe4181"],"StartPositionTicks":1230000000,"PlayCommand":"PlayNow","ControllingUserId":"fabef5b2fd88436d8cf985ebfd35bce9"},"MessageType":"Play"}
    """#
    static let pause = #"{"MessageId":"a1","Data":{"Command":"Pause","ControllingUserId":"fabef5b2fd88436d8cf985ebfd35bce9"},"MessageType":"Playstate"}"#
    static let seek = #"{"MessageId":"a2","Data":{"Command":"Seek","SeekPositionTicks":600000000,"ControllingUserId":"fabef5b2fd88436d8cf985ebfd35bce9"},"MessageType":"Playstate"}"#
    static let subtitle = #"{"MessageId":"a3","Data":{"Name":"SetSubtitleStreamIndex","ControllingUserId":"fabef5b2fd88436d8cf985ebfd35bce9","Arguments":{"Index":"3"}},"MessageType":"GeneralCommand"}"#
}

private func message(_ json: String) throws -> SocketMessage {
    try SocketMessage(json: Data(json.utf8))
}

struct SocketMessageTests {
    @Test func readsTheKeepAliveTimeout() throws {
        #expect(try message(Captured.forceKeepAlive) == .forceKeepAlive(60))
        #expect(try message(Captured.keepAlive) == .keepAlive)
    }

    @Test func keepsTheNameOfMessagesItHasNoUseFor() throws {
        #expect(try message(#"{"MessageType":"UserDataChanged","Data":{"UserId":"x"}}"#) == .other("UserDataChanged"))
    }

    @Test func refusesAMessageWithoutAType() {
        #expect(throws: DecodingError.self) { try message(#"{"Data":60}"#) }
    }

    @Test func readsASession() throws {
        // vinnyfin on Apple TV playing a movie, in the socket's Sessions message, whose sessions
        // are the ones `GET /Sessions` lists.
        struct Message: Decodable {
            let sessions: [RemoteSession]
            enum CodingKeys: String, CodingKey { case sessions = "Data" }
        }
        let session = try #require(try JSONDecoder().decode(Message.self, from: Samples.fixture("sessions-message")).sessions.first)
        #expect(session.id == "58cd291dfd5f1dfc9c47086b7393af9d")
        #expect(session.client == "vinnyfin tvOS")
        #expect(session.isVinnyfin)
        #expect(session.deviceName == "vinnyfin together: Apple TV")
        #expect(session.supportsRemoteControl)
        #expect(session.supports(.setSubtitleStreamIndex))
        #expect(session.position == 148.4983668)
        #expect(!session.playState.isPaused)
        #expect(session.nowPlayingItem?.name == "Sync Movie (2024)")
        #expect(session.nowPlayingItem?.runtimeSeconds == 300.023)
    }

    @Test func sendsAKeepAlive() {
        #expect(SocketMessage.Outbound.keepAlive.json == #"{"MessageType":"KeepAlive"}"#)
    }

    @Test func reportsWhatThisAppObeys() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientCapabilities())) as? [String: Any]
        #expect(json?["PlayableMediaTypes"] as? [String] == ["Video"])
        #expect(json?["SupportedCommands"] as? [String] == ["SetAudioStreamIndex", "SetSubtitleStreamIndex", "Play", "PlayState"])
        #expect(json?["SupportsMediaControl"] as? Bool == true)
    }

    @Test func sendsAGeneralCommandWithItsArguments() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GeneralCommand(.setAudioStreamIndex, arguments: ["Index": "2"])))
            as? [String: Any]
        #expect(json?["Name"] as? String == "SetAudioStreamIndex")
        #expect(json?["Arguments"] as? [String: String] == ["Index": "2"])
    }
}

struct RemoteCommandTests {
    @Test func playsTheFirstItemFromTheStartAsked() throws {
        let command = RemoteCommand(try message(Captured.play))
        #expect(command == .play(itemId: "2b60d7fcb1c30c67852b1bb4241b50e8", start: 123, mediaSourceId: nil,
                                 audioStreamIndex: nil, subtitleStreamIndex: nil))
    }

    @Test func playsTheItemAtTheStartIndexWithTheStreamsAsked() throws {
        let json = #"{"MessageType":"Play","Data":{"ItemIds":["a","b"],"StartIndex":1,"PlayCommand":"PlayNow","MediaSourceId":"b-source","AudioStreamIndex":2,"SubtitleStreamIndex":-1}}"#
        #expect(RemoteCommand(try message(json)) == .play(itemId: "b", start: 0, mediaSourceId: "b-source",
                                                           audioStreamIndex: 2, subtitleStreamIndex: -1))
    }

    @Test func leavesQueueingAndBadIndicesAlone() throws {
        let next = #"{"MessageType":"Play","Data":{"ItemIds":["a"],"PlayCommand":"PlayNext"}}"#
        let last = #"{"MessageType":"Play","Data":{"ItemIds":["a"],"PlayCommand":"PlayLast"}}"#
        let outOfRange = #"{"MessageType":"Play","Data":{"ItemIds":["a"],"StartIndex":3,"PlayCommand":"PlayNow"}}"#
        #expect(RemoteCommand(try message(next)) == nil)
        #expect(RemoteCommand(try message(last)) == nil)
        #expect(RemoteCommand(try message(outOfRange)) == nil)
    }

    @Test func mapsTheTransport() throws {
        func playstate(_ command: String, ticks: Int64? = nil) throws -> RemoteCommand? {
            let seek = ticks.map { #","SeekPositionTicks":\#($0)"# } ?? ""
            return RemoteCommand(try message(#"{"MessageType":"Playstate","Data":{"Command":"\#(command)"\#(seek)}}"#))
        }
        #expect(RemoteCommand(try message(Captured.pause)) == .pause)
        #expect(RemoteCommand(try message(Captured.seek)) == .seek(60))
        #expect(try playstate("Unpause") == .unpause)
        #expect(try playstate("PlayPause") == .togglePause)
        #expect(try playstate("Stop") == .stop)
        #expect(try playstate("NextTrack") == .nextEpisode)
        #expect(try playstate("PreviousTrack") == .previousEpisode)
        #expect(try playstate("Rewind") == .skip(-10))
        #expect(try playstate("FastForward") == .skip(10))
        #expect(try playstate("Seek") == nil)
        #expect(try playstate("Shuffle") == nil)
    }

    @Test func mapsTheStreamChanges() throws {
        func general(_ name: String, index: String) throws -> RemoteCommand? {
            RemoteCommand(try message(#"{"MessageType":"GeneralCommand","Data":{"Name":"\#(name)","Arguments":{"Index":"\#(index)"}}}"#))
        }
        #expect(RemoteCommand(try message(Captured.subtitle)) == .subtitleStream(3))
        #expect(try general("SetSubtitleStreamIndex", index: "-1") == .subtitleStream(nil))
        #expect(try general("SetAudioStreamIndex", index: "2") == .audioStream(2))
        #expect(try general("SetAudioStreamIndex", index: "two") == nil)
        #expect(try general("SetVolume", index: "2") == nil)
    }

    @Test func otherMessagesAreNoCommands() throws {
        #expect(RemoteCommand(try message(Captured.forceKeepAlive)) == nil)
        #expect(RemoteCommand(try SocketMessage(json: Samples.fixture("sessions-message"))) == nil)
    }
}

private func session(_ id: String, client: String, name: String) -> RemoteSession {
    RemoteSession(id: id, client: client, deviceName: name, deviceId: "device-\(id)")
}

struct PlayTargetTests {
    @Test func namesTheDeviceOrElseTheApp() {
        #expect(PlayTarget(session: session("1", client: "vinnyfin tvOS", name: "Living Room")).name == "Living Room")
        #expect(PlayTarget(session: session("1", client: "Jellyfin Web", name: "")).name == "Jellyfin Web")
    }

    @Test func picksASymbolForTheDevice() {
        #expect(PlayTarget(session: session("1", client: "vinnyfin tvOS", name: "")).symbol == "appletv")
        #expect(PlayTarget(session: session("1", client: "vinnyfin iOS", name: "")).symbol == "ipad.and.iphone")
        #expect(PlayTarget(session: session("1", client: "vinnyfin macOS", name: "")).symbol == "laptopcomputer")
        #expect(PlayTarget(session: session("1", client: "Jellyfin Web", name: "")).symbol == "globe")
        #expect(PlayTarget(session: session("1", client: "Jellyfin Android TV", name: "")).symbol == "tv")
    }

    @Test func namesEachPlatformsVinnyfinApart() {
        #expect(JellyfinClient.clientName(for: .tvOS) == "vinnyfin tvOS")
        #expect(JellyfinClient.clientName(for: .iOS) == "vinnyfin iOS")
    }
}

struct StreamIndexMapTests {
    private func stream(_ type: String, _ index: Int, language: String? = nil, external: Bool = false) -> MediaStream {
        var stream = MediaStream(type: type)
        stream.index = index
        stream.language = language
        stream.isExternal = external
        stream.codec = "subrip"
        return stream
    }

    private func track(_ id: Int, language: String? = nil, external: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: language ?? "Track", codec: "subrip", language: language, isDefault: false, isExternal: external)
    }

    @Test func anEmbeddedStreamIsItsTrack() {
        let map = StreamIndexMap(streams: [stream("Video", 0), stream("Audio", 1), stream("Subtitle", 2)],
                                 tracks: [track(1), track(2)])
        #expect(map.trackId(forStream: 2) == 2)
        #expect(map.streamIndex(forTrack: 1) == 1)
        #expect(map.trackId(forStream: 0) == nil)
    }

    @Test func externalSubtitlesGoInTheServersOrder() {
        let base = AetherEngine.externalSubtitleTrackIDBase
        let map = StreamIndexMap(streams: [stream("Audio", 0), stream("Subtitle", 1, language: "eng", external: true),
                                           stream("Subtitle", 2, language: "fra", external: true)],
                                 tracks: [track(0), track(base + 1, language: "fra", external: true), track(base, language: "eng", external: true)])
        #expect(map.trackId(forStream: 1) == base)
        #expect(map.trackId(forStream: 2) == base + 1)
        #expect(map.streamIndex(forTrack: base + 1) == 2)
    }

    @Test func externalSubtitlesMatchByLanguageWhenSomeDidntLoad() {
        let base = AetherEngine.externalSubtitleTrackIDBase
        let map = StreamIndexMap(streams: [stream("Subtitle", 4, language: "eng", external: true),
                                           stream("Subtitle", 5, language: "fra", external: true)],
                                 tracks: [track(base, language: "fra", external: true)])
        #expect(map.trackId(forStream: 5) == base)
        #expect(map.trackId(forStream: 4) == nil)
    }
}
