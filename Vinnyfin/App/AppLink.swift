import Foundation

/// A link into the app, as Apple TV's Top Shelf, the widgets, notifications and Handoff hand it
/// over: `vinnyfin://item/<id>?type=…&name=…` opens a title's page, and
/// `vinnyfin://play/<id>?type=…&name=…` plays it from where it was left, or with
/// `&position=<seconds>` from there at the earliest. The type and name let the page or the player
/// open before the server has answered. `&server=<id>&user=<id>` say whose title it is, for a link
/// written for one sign-in: it opens under that sign-in, whichever is in use when it's followed.
nonisolated struct AppLink: Equatable, Sendable {
    enum Action: String, Sendable {
        case open = "item"
        case play
    }

    /// The server and user a link's title is from.
    struct Owner: Codable, Hashable, Sendable {
        var serverId: String
        var userId: String

        init(serverId: String, userId: String) {
            self.serverId = serverId
            self.userId = userId
        }

        init(_ account: AccountStore.Account) {
            self.init(serverId: account.serverId, userId: account.userId)
        }

        /// Whether `account` is this person on this server.
        func isSignedIn(as account: AccountStore.Account?) -> Bool {
            account?.serverId == serverId && account?.userId == userId
        }
    }

    static let scheme = "vinnyfin"

    var action: Action
    var itemId: String
    var type: String
    var name: String
    /// Where another device had got to, in whole seconds, for a playback continued from it.
    var position: Double?
    /// Whose title it is; nil for a link that doesn't say, which opens under the sign-in in use.
    var owner: Owner?

    init(_ action: Action, _ item: JellyfinItem, position: Double? = nil, owner: Owner? = nil) {
        self.action = action
        itemId = item.id
        type = item.type
        name = item.name
        self.position = position.flatMap(Self.wholeSeconds)
        self.owner = owner
    }

    init(_ action: Action, _ item: JellyfinItem, position: Double? = nil, for account: AccountStore.Account?) {
        self.init(action, item, position: position, owner: account.map(Owner.init))
    }

    /// Nil when the URL isn't a link into the app.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = components.host.flatMap({ Action(rawValue: $0.lowercased()) })
        else { return nil }
        let itemId = String(components.path.dropFirst())
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        guard components.path.hasPrefix("/"), !itemId.isEmpty, !itemId.contains("/"),
              let type = value("type"), !type.isEmpty,
              let name = value("name")
        else { return nil }
        self.action = action
        self.itemId = itemId
        self.type = type
        self.name = name
        position = value("position").flatMap(Double.init).flatMap(Self.wholeSeconds)
        // Both or neither: a link naming only the server says nothing of whose title it is.
        if let serverId = value("server"), !serverId.isEmpty, let userId = value("user"), !userId.isEmpty {
            owner = Owner(serverId: serverId, userId: userId)
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        components.path = "/" + itemId
        var query = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "name", value: name)]
        if let position { query.append(URLQueryItem(name: "position", value: String(format: "%.0f", position))) }
        if let owner { query += [URLQueryItem(name: "server", value: owner.serverId), URLQueryItem(name: "user", value: owner.userId)] }
        components.queryItems = query
        // A scheme, a host and a path that starts with a slash always make a URL.
        return components.url!
    }

    /// The title as far as the link describes it; its page and the player load the rest.
    var item: JellyfinItem {
        JellyfinItem(id: itemId, name: name, type: type)
    }

    /// A position as the link carries it; nil for one that isn't a time into the title.
    private static func wholeSeconds(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds >= 0 ? seconds.rounded(.down) : nil
    }
}

/// Which sign-in a title from a particular one opens under on this device: a link that says
/// whose title it is, or a title another device handed off.
nonisolated enum SignInChoice: Equatable, Sendable {
    /// The sign-in in use is the one.
    case inUse
    /// Another sign-in kept on this device is, which switching to needs no password.
    case switchTo(AccountStore.Account)
    /// No sign-in on this device is: it has to be added, beside the one in use.
    case add

    /// For a title of `owner`'s, with `inUse` in use among the sign-ins `kept` here.
    static func choose(for owner: AppLink.Owner, inUse: AccountStore.Account?, kept: [AccountStore.Account]) -> SignInChoice {
        if owner.isSignedIn(as: inUse) { return .inUse }
        if let account = kept.first(where: { owner.isSignedIn(as: $0) }) { return .switchTo(account) }
        return .add
    }
}
