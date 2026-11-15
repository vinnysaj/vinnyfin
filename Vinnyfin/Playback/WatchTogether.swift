import CoreTransferable
import Foundation
import GroupActivities
import ImageIO

/// Watching a title together over SharePlay: the server it plays from and the title, which
/// changes as the group moves to another episode. Everyone plays it from their own sign-in to
/// that server, so only people with access to it can join; someone with a sign-in to it kept on
/// their device is offered to switch to it.
nonisolated struct WatchTogether: GroupActivity, Hashable {
    static let activityIdentifier = "net.vinnysaj.vinnyfin.watch-together"

    /// The server's own id, the same at every address it's reached by.
    var serverId: String
    var serverName: String
    var itemId: String
    var title: String
    var subtitle: String?
    /// The title's poster as a small JPEG, for FaceTime's card of the activity on the device that
    /// starts it. It stays there: the others get the card, not the activity's picture.
    var preview: Data?

    private enum CodingKeys: String, CodingKey {
        case serverId, serverName, itemId, title, subtitle
    }

    init(serverId: String, serverName: String, itemId: String, title: String, subtitle: String? = nil, preview: Data? = nil) {
        self.serverId = serverId
        self.serverName = serverName
        self.itemId = itemId
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
    }

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .watchTogether
        metadata.title = title
        metadata.subtitle = subtitle
        metadata.previewImage = preview.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        // An iPhone on a call can hand the activity to an Apple TV, which plays it in vinnyfin there.
        metadata.supportsContinuationOnTV = true
        return metadata
    }

    /// The sign-ins kept on this device to the server the group plays from, which can join it.
    func keptSignIns(among saved: [AccountStore.Account]) -> [AccountStore.Account] {
        saved.filter { $0.serverId == serverId }
    }

    /// Asks someone signed in elsewhere, with sign-ins to the group's server kept here, whether to
    /// switch to one to watch together; `isPlaying` when something plays here, which switching stops.
    func switchQuestion(signedIn account: AccountStore.Account?, kept: [AccountStore.Account], isPlaying: Bool) -> String {
        let here = account.map { "vinnyfin here is using \($0.serverTitle) as \($0.userName)." } ?? "vinnyfin here isn't signed in."
        let who = kept.count == 1 ? "\(kept[0].userName)'s sign-in to it is kept here" : "Sign-ins to it are kept here"
        let stays = account.map { " \($0.userName) stays signed in to switch back to." } ?? ""
        let stops = isPlaying ? " What's playing here stops." : ""
        return "\(title) is playing from \(serverName). \(here) \(who), so switching needs no password.\(stays)\(stops)"
    }

    /// Whether someone signed in to `account`, or to nothing, can play what the group plays.
    enum Access: Equatable, Sendable {
        case allowed
        case notSignedIn
        case otherServer(String)
    }

    func access(for account: AccountStore.Account?) -> Access {
        guard let account else { return .notSignedIn }
        return account.serverId == serverId ? .allowed : .otherServer(account.serverName ?? account.serverURL.host() ?? "another server")
    }

    /// What this device says when it can't join.
    func refusal(_ access: Access) -> String? {
        switch access {
        case .allowed:
            nil
        case .notSignedIn:
            "\(title) is playing from \(serverName). Sign in to \(serverName) in vinnyfin to watch together."
        case .otherServer(let other):
            "\(title) is playing from \(serverName), and vinnyfin here is signed in to \(other). Sign in to \(serverName) to watch together."
        }
    }
}

/// Told to the group by someone who can't watch with it.
nonisolated struct CantWatch: Codable, Equatable, Sendable {
    enum Reason: Codable, Equatable, Sendable {
        case notSignedIn
        case otherServer
        /// The title didn't play: the message the player gave.
        case failed(String)
    }

    var reason: Reason

    init(_ reason: Reason) {
        self.reason = reason
    }

    init?(_ access: WatchTogether.Access) {
        switch access {
        case .allowed: return nil
        case .notSignedIn: reason = .notSignedIn
        case .otherServer: reason = .otherServer
        }
    }

    /// How the others are told, in a list of everyone who can't watch.
    func describe(serverName: String) -> String {
        switch reason {
        case .notSignedIn: "Someone isn't signed in to \(serverName)."
        case .otherServer: "Someone is signed in to a different server than \(serverName)."
        case .failed(let message): "It didn't play for someone: \(message)"
        }
    }
}
