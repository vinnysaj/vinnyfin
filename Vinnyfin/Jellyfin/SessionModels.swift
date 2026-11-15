import Foundation

/// One signed-in app on one device, as `GET /Sessions` lists it: what it can be asked to do and
/// what it's playing.
nonisolated struct RemoteSession: Decodable, Identifiable, Equatable, Sendable {
    struct PlayState: Decodable, Equatable, Sendable {
        var positionTicks: Int64?
        var isPaused = false
        var canSeek = false

        enum CodingKeys: String, CodingKey {
            case positionTicks = "PositionTicks", isPaused = "IsPaused", canSeek = "CanSeek"
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            positionTicks = try container.decodeIfPresent(Int64.self, forKey: .positionTicks)
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
            canSeek = try container.decodeIfPresent(Bool.self, forKey: .canSeek) ?? false
        }
    }

    let id: String
    var client: String
    var deviceName: String
    var deviceId: String
    var supportsRemoteControl: Bool
    /// `GeneralCommandType` names, such as "SetSubtitleStreamIndex".
    var supportedCommands: [String]
    var nowPlayingItem: JellyfinItem?
    var playState: PlayState

    enum CodingKeys: String, CodingKey {
        case id = "Id", client = "Client", deviceName = "DeviceName", deviceId = "DeviceId"
        case supportsRemoteControl = "SupportsRemoteControl"
        case supportedCommands = "SupportedCommands", nowPlayingItem = "NowPlayingItem", playState = "PlayState"
    }

    init(id: String, client: String, deviceName: String, deviceId: String, supportsRemoteControl: Bool = true,
         supportedCommands: [String] = []) {
        self.id = id
        self.client = client
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.supportsRemoteControl = supportsRemoteControl
        self.supportedCommands = supportedCommands
        playState = PlayState()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        client = try container.decodeIfPresent(String.self, forKey: .client) ?? ""
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        supportsRemoteControl = try container.decodeIfPresent(Bool.self, forKey: .supportsRemoteControl) ?? false
        supportedCommands = try container.decodeIfPresent([String].self, forKey: .supportedCommands) ?? []
        nowPlayingItem = try container.decodeIfPresent(JellyfinItem.self, forKey: .nowPlayingItem)
        playState = try container.decodeIfPresent(PlayState.self, forKey: .playState) ?? PlayState()
    }

    var isVinnyfin: Bool { client.hasPrefix(JellyfinClient.clientName) }

    var position: Double { Double(playState.positionTicks ?? 0) / 10_000_000 }

    func supports(_ command: GeneralCommandName) -> Bool { supportedCommands.contains(command.rawValue) }
}

/// The `GeneralCommandType`s this app sends or obeys, by the names the server uses.
nonisolated enum GeneralCommandName: String, Sendable {
    case setAudioStreamIndex = "SetAudioStreamIndex"
    case setSubtitleStreamIndex = "SetSubtitleStreamIndex"
    case play = "Play"
    case playState = "PlayState"
    case moveUp = "MoveUp"
    case moveDown = "MoveDown"
    case moveLeft = "MoveLeft"
    case moveRight = "MoveRight"
    case select = "Select"
    case back = "Back"
    case goHome = "GoHome"
    case sendString = "SendString"
    case sendKey = "SendKey"
    case toggleFullscreen = "ToggleFullscreen"
    case volumeUp = "VolumeUp"
    case volumeDown = "VolumeDown"
    case toggleMute = "ToggleMute"
}

/// What a session tells the server it can do, which makes it a target of remote control while
/// its socket is open.
nonisolated struct ClientCapabilities: Encodable, Equatable, Sendable {
    var PlayableMediaTypes = ["Video"]
    var SupportedCommands: [String] = [
        GeneralCommandName.setAudioStreamIndex, .setSubtitleStreamIndex, .play, .playState,
    ].map(\.rawValue)
    var SupportsMediaControl = true
    var SupportsPersistentIdentifier = true

    /// While Portable TV shows `space`, the presses it takes there too. A remote lists the
    /// sessions that take presses as TVs, and reads from them which kind of remote to be.
    static func portableTV(showing space: TVSpace) -> ClientCapabilities {
        var capabilities = ClientCapabilities()
        capabilities.SupportedCommands += TVPress.commands(in: space).map(\.rawValue)
        return capabilities
    }
}

/// What Portable TV shows: the library, or YouTube's website.
nonisolated enum TVSpace: String, CaseIterable, Sendable {
    case library = "Library"
    case youTube = "YouTube"
}

/// A press of the remote of a device showing Portable TV, sent through the server as Jellyfin's
/// remotes send theirs. The library moves focus with the moves and Select; YouTube's website is
/// made for a pointer, which this app's remote moves with `SendKey`, a command Jellyfin's remotes
/// send only to type a key, so only to a vinnyfin TV. Sleep is a `SendKey` too.
nonisolated enum TVPress: Equatable, Sendable {
    case up, down, left, right, select, back
    /// Home of the library or YouTube; nil for the one showing.
    case home(TVSpace?)
    /// What to search for, in full, as typed so far.
    case text(String)
    /// The pointer moved to `x` and `y`, fractions of the screen's width and height from its top left.
    case point(x: Double, y: Double)
    /// A click where the pointer is, at `x` and `y` as in `point`.
    case click(x: Double, y: Double)
    /// A scroll by points, positive moving the page's content up and left as a trackpad does.
    case scroll(dx: Double, dy: Double)
    /// The video on the page fills the screen, or stops filling it, with `ToggleFullscreen`.
    case fullScreen
    case volumeUp, volumeDown
    /// Turns the sound off, or back on.
    case mute
    /// Closes the app on the TV and puts the Mac it runs on to sleep.
    case sleep

    /// The commands that make a session a TV: every TV takes them, wherever it is.
    static let ofEveryTV: [GeneralCommandName] = [.select, .back, .goHome, .sendString]
    /// The volume's commands. A remote has volume buttons for a TV that takes them.
    static let ofVolume: [GeneralCommandName] = [.volumeUp, .volumeDown, .toggleMute]

    /// The commands a TV takes in `space`: those of every TV and the volume's, and the moves in
    /// the library, the pointer on YouTube.
    static func commands(in space: TVSpace) -> [GeneralCommandName] {
        switch space {
        case .library: [.moveUp, .moveDown, .moveLeft, .moveRight] + ofEveryTV + ofVolume
        case .youTube: ofEveryTV + [.sendKey, .toggleFullscreen] + ofVolume
        }
    }

    /// The general command that sends the press.
    var command: GeneralCommand {
        switch self {
        case .up: GeneralCommand(.moveUp)
        case .down: GeneralCommand(.moveDown)
        case .left: GeneralCommand(.moveLeft)
        case .right: GeneralCommand(.moveRight)
        case .select: GeneralCommand(.select)
        case .back: GeneralCommand(.back)
        case .home(let space): GeneralCommand(.goHome, arguments: space.map { [Self.homeKey: $0.rawValue] } ?? [:])
        case .text(let text): GeneralCommand(.sendString, arguments: ["String": text])
        case .point(let x, let y): Self.key(.point, ["X": Self.format(x), "Y": Self.format(y)])
        case .click(let x, let y): Self.key(.click, ["X": Self.format(x), "Y": Self.format(y)])
        case .scroll(let dx, let dy): Self.key(.scroll, ["X": Self.format(dx), "Y": Self.format(dy)])
        case .fullScreen: GeneralCommand(.toggleFullscreen)
        case .volumeUp: GeneralCommand(.volumeUp)
        case .volumeDown: GeneralCommand(.volumeDown)
        case .mute: GeneralCommand(.toggleMute)
        case .sleep: Self.key(.sleep)
        }
    }

    /// Nil for a command that isn't a press.
    init?(_ command: GeneralCommand) {
        func number(_ key: String) -> Double? { command.arguments[key].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        switch GeneralCommandName(rawValue: command.name) {
        case .moveUp: self = .up
        case .moveDown: self = .down
        case .moveLeft: self = .left
        case .moveRight: self = .right
        case .select: self = .select
        case .back: self = .back
        // A home this app doesn't know is Home of the one showing.
        case .goHome: self = .home(command.arguments[Self.homeKey].flatMap(TVSpace.init))
        case .sendString:
            guard let text = command.arguments["String"] else { return nil }
            self = .text(text)
        case .toggleFullscreen:
            self = .fullScreen
        case .volumeUp: self = .volumeUp
        case .volumeDown: self = .volumeDown
        case .toggleMute: self = .mute
        case .sendKey:
            switch command.arguments["Key"].flatMap(Key.init) {
            case .point:
                guard let x = number("X"), let y = number("Y") else { return nil }
                self = .point(x: x, y: y)
            case .click:
                guard let x = number("X"), let y = number("Y") else { return nil }
                self = .click(x: x, y: y)
            case .scroll:
                guard let dx = number("X"), let dy = number("Y") else { return nil }
                self = .scroll(dx: dx, dy: dy)
            case .sleep:
                self = .sleep
            case nil:
                return nil
            }
        default:
            return nil
        }
    }

    /// The `Key` of a `SendKey` that moves the pointer, clicks, scrolls, or sleeps the TV.
    private enum Key: String {
        case point = "Pointer", click = "Click", scroll = "Scroll", sleep = "Sleep"
    }

    private static let homeKey = "Home"

    private static func key(_ key: Key, _ arguments: [String: String] = [:]) -> GeneralCommand {
        GeneralCommand(.sendKey, arguments: arguments.merging(["Key": key.rawValue]) { _, new in new })
    }

    /// Short enough to send many a second, fine enough for a pixel on an 8K screen.
    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...5)).locale(Locale(identifier: "en_US_POSIX")).grouping(.never))
    }
}

/// A general command, such as a subtitle change, as it's sent to `/Sessions/{id}/Command` and
/// arrives over the socket.
nonisolated struct GeneralCommand: Codable, Equatable, Sendable {
    var name: String
    var arguments: [String: String]

    enum CodingKeys: String, CodingKey {
        case name = "Name", arguments = "Arguments"
    }

    init(_ name: GeneralCommandName, arguments: [String: String] = [:]) {
        self.name = name.rawValue
        self.arguments = arguments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
    }
}

/// The transport commands of `/Sessions/{id}/Playing/{command}`, by the server's names.
nonisolated enum PlaystateCommand: String, Codable, Sendable {
    case stop = "Stop", pause = "Pause", unpause = "Unpause", playPause = "PlayPause"
    case nextTrack = "NextTrack", previousTrack = "PreviousTrack", seek = "Seek"
    case rewind = "Rewind", fastForward = "FastForward"
}

/// A message from the server over `/socket`. Kinds this app has no use for are kept by name.
nonisolated enum SocketMessage: Equatable, Sendable {
    struct PlayRequest: Decodable, Equatable, Sendable {
        var itemIds: [String]
        var startPositionTicks: Int64?
        var playCommand: String
        var mediaSourceId: String?
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var startIndex: Int?

        enum CodingKeys: String, CodingKey {
            case itemIds = "ItemIds", startPositionTicks = "StartPositionTicks", playCommand = "PlayCommand"
            case mediaSourceId = "MediaSourceId", audioStreamIndex = "AudioStreamIndex"
            case subtitleStreamIndex = "SubtitleStreamIndex", startIndex = "StartIndex"
        }
    }

    struct PlaystateRequest: Decodable, Equatable, Sendable {
        var command: String
        var seekPositionTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case command = "Command", seekPositionTicks = "SeekPositionTicks"
        }
    }

    /// The server closes a socket that says nothing for this long, in seconds.
    case forceKeepAlive(Int)
    case keepAlive
    case play(PlayRequest)
    case playstate(PlaystateRequest)
    case generalCommand(GeneralCommand)
    case other(String)

    private struct Envelope: Decodable {
        let messageType: String
        enum CodingKeys: String, CodingKey { case messageType = "MessageType" }
    }

    private struct Payload<Data: Decodable>: Decodable {
        let data: Data
        enum CodingKeys: String, CodingKey { case data = "Data" }
    }

    init(json: Data) throws {
        let decoder = JSONDecoder()
        let type = try decoder.decode(Envelope.self, from: json).messageType
        switch type {
        case "ForceKeepAlive": self = .forceKeepAlive(try decoder.decode(Payload<Int>.self, from: json).data)
        case "KeepAlive": self = .keepAlive
        case "Play": self = .play(try decoder.decode(Payload<PlayRequest>.self, from: json).data)
        case "Playstate": self = .playstate(try decoder.decode(Payload<PlaystateRequest>.self, from: json).data)
        case "GeneralCommand": self = .generalCommand(try decoder.decode(Payload<GeneralCommand>.self, from: json).data)
        default: self = .other(type)
        }
    }

    /// What this app sends over the socket: keep-alives.
    enum Outbound: Equatable, Sendable {
        case keepAlive

        var json: String {
            switch self {
            case .keepAlive:
                #"{"MessageType":"KeepAlive"}"#
            }
        }
    }
}

/// What another device asks the player here to do, worked out from the server's messages.
nonisolated enum RemoteCommand: Equatable, Sendable {
    /// Plays a server item from `start` seconds, in the version and with the streams given, when given.
    case play(itemId: String, start: Double, mediaSourceId: String?, audioStreamIndex: Int?, subtitleStreamIndex: Int?)
    case pause
    case unpause
    case togglePause
    case stop
    case seek(Double)
    case skip(Double)
    case nextEpisode
    case previousEpisode
    case audioStream(Int)
    /// Nil turns subtitles off.
    case subtitleStream(Int?)
    /// A press of the remote of a device showing Portable TV.
    case tv(TVPress)

    /// How far Rewind and Fast Forward move, as the player's own skip buttons do.
    static let skipInterval: Double = 10

    /// Nil for messages that aren't commands, and for commands this app doesn't obey, such as
    /// queueing an item to play later.
    init?(_ message: SocketMessage) {
        switch message {
        case .play(let request):
            guard request.playCommand == "PlayNow" else { return nil }
            let index = request.startIndex ?? 0
            guard request.itemIds.indices.contains(index) else { return nil }
            // A start the controller leaves out is the beginning, as every Jellyfin player reads it.
            self = .play(itemId: request.itemIds[index], start: Double(request.startPositionTicks ?? 0) / 10_000_000,
                         mediaSourceId: request.mediaSourceId, audioStreamIndex: request.audioStreamIndex,
                         subtitleStreamIndex: request.subtitleStreamIndex)
        case .playstate(let request):
            switch PlaystateCommand(rawValue: request.command) {
            case .stop: self = .stop
            case .pause: self = .pause
            case .unpause: self = .unpause
            case .playPause: self = .togglePause
            case .nextTrack: self = .nextEpisode
            case .previousTrack: self = .previousEpisode
            case .rewind: self = .skip(-Self.skipInterval)
            case .fastForward: self = .skip(Self.skipInterval)
            case .seek:
                guard let ticks = request.seekPositionTicks else { return nil }
                self = .seek(Double(ticks) / 10_000_000)
            case nil: return nil
            }
        case .generalCommand(let command):
            if let press = TVPress(command) {
                self = .tv(press)
                return
            }
            guard let index = command.arguments["Index"].flatMap(Int.init) else { return nil }
            switch GeneralCommandName(rawValue: command.name) {
            case .setAudioStreamIndex: self = .audioStream(index)
            case .setSubtitleStreamIndex: self = .subtitleStream(index < 0 ? nil : index)
            default: return nil
            }
        case .forceKeepAlive, .keepAlive, .other:
            return nil
        }
    }
}

/// A session this app can be the remote for, named and given a symbol for the remote's list of TVs.
nonisolated struct PlayTarget: Identifiable, Equatable, Sendable {
    let session: RemoteSession

    var id: String { session.id }
    var name: String { session.deviceName.isEmpty ? session.client : session.deviceName }

    /// The device's symbol: vinnyfin says what it runs on, and the web app is a browser.
    var symbol: String {
        switch session.client {
        case JellyfinClient.clientName(for: .tvOS): "appletv"
        case JellyfinClient.clientName(for: .iOS): "ipad.and.iphone"
        case JellyfinClient.clientName(for: .macOS): "laptopcomputer"
        case JellyfinClient.clientName(for: .visionOS): "visionpro"
        case let client where client.localizedCaseInsensitiveContains("web"): "globe"
        default: "tv"
        }
    }
}

extension PlayTarget {
    /// The sessions a remote can drive, other than this device's: vinnyfin showing Portable TV
    /// first, then other apps that take a remote's presses, as Jellyfin's web app does, each by name.
    static func televisions(from sessions: [RemoteSession], excludingDeviceId deviceId: String) -> [PlayTarget] {
        let required = TVPress.ofEveryTV.map(\.rawValue)
        return sessions
            .filter { $0.deviceId != deviceId && $0.supportsRemoteControl && Set($0.supportedCommands).isSuperset(of: required) }
            .map(PlayTarget.init)
            .sorted { lhs, rhs in
                if lhs.session.isVinnyfin != rhs.session.isVinnyfin { return lhs.session.isVinnyfin }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    /// What the TV shows, for the remote to match: YouTube while a vinnyfin TV takes the pointer
    /// there, the library otherwise. Other apps take a key with `SendKey`, not the pointer.
    var tvSpace: TVSpace {
        session.isVinnyfin && session.supports(.sendKey) ? .youTube : .library
    }

    /// The TV has YouTube to switch to: vinnyfin's does.
    var hasYouTube: Bool { session.isVinnyfin }

    var takesVolume: Bool { TVPress.ofVolume.allSatisfy(session.supports) }

    /// The TV can be put to sleep from the remote: vinnyfin's, which is a Mac, can.
    var sleeps: Bool { session.isVinnyfin }
}
