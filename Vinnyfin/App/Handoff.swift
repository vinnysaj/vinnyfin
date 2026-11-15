import AppIntents
import SwiftUI

/// What a device hands to the person's other devices through Handoff: the title whose page is
/// open, or the one playing and how far it got, and the server and person it's from. Continuing
/// on the other device opens the title as a link into the app does. The activity names the
/// server's address, so a device signed in elsewhere can offer to sign in to it. Apple TV takes
/// no part: tvOS neither offers activities to other devices nor continues them.
nonisolated struct Handoff: Equatable, Sendable {
    /// The activity vinnyfin hands off, as listed under `NSUserActivityTypes` in Info.plist: a
    /// title's page or its playback, which the link tells apart.
    static let activityType = "net.vinnysaj.vinnyfin.title"

    var link: AppLink
    var signIn: ServerSignIn

    private enum Key {
        static let link = "link"
        static let serverId = "serverId"
        static let serverName = "serverName"
        static let serverAddress = "serverAddress"
        static let userId = "userId"
        static let userName = "userName"
    }

    init(link: AppLink, signIn: ServerSignIn) {
        self.link = link
        self.signIn = signIn
    }

    /// Nil for another app's activity, or one that's missing something.
    init?(_ activity: NSUserActivity) {
        guard activity.activityType == Self.activityType else { return nil }
        self.init(userInfo: activity.userInfo ?? [:])
    }

    init?(userInfo: [AnyHashable: Any]) {
        func string(_ key: String) -> String? {
            (userInfo[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let link = string(Key.link).flatMap(URL.init(string:)).flatMap(AppLink.init),
              let serverId = string(Key.serverId),
              let address = string(Key.serverAddress).flatMap(URL.init(string:)),
              let userId = string(Key.userId),
              let userName = string(Key.userName)
        else { return nil }
        self.link = link
        signIn = ServerSignIn(serverId: serverId, serverName: string(Key.serverName), address: address,
                              userId: userId, userName: userName)
    }

    var userInfo: [String: String] {
        var info = [
            Key.link: link.url.absoluteString,
            Key.serverId: signIn.serverId,
            Key.serverAddress: signIn.address.absoluteString,
            Key.userId: signIn.userId,
            Key.userName: signIn.userName,
        ]
        info[Key.serverName] = signIn.serverName
        return info
    }

    /// Jellyfin's own page for the title, which a device without vinnyfin opens in its browser.
    var webpageURL: URL? {
        Self.webpageURL(itemId: link.itemId, serverId: signIn.serverId, address: signIn.address)
    }

    /// Jellyfin's own page for an item, in the web app of the server at `address`. Nil for an
    /// address a browser can't open.
    static func webpageURL(itemId: String, serverId: String, address: URL) -> URL? {
        guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased())
        else { return nil }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "web/"
        components.query = nil
        var route = URLComponents()
        route.path = "/details"
        route.queryItems = [URLQueryItem(name: "id", value: itemId), URLQueryItem(name: "serverId", value: serverId)]
        components.fragment = route.string
        return components.url
    }

    /// Fills in the activity for the other devices to offer.
    func describe(_ activity: NSUserActivity) {
        activity.title = link.name
        activity.userInfo = userInfo
        activity.requiredUserInfoKeys = Set(userInfo.keys)
        activity.webpageURL = webpageURL
        activity.isEligibleForHandoff = true
    }

    // MARK: Another sign-in

    /// How this device's sign-in differs from the one the title came from.
    enum Mismatch: Equatable, Sendable {
        case notSignedIn
        case otherServer(AccountStore.Account)
        case otherUser(AccountStore.Account)
    }

    /// Nil when this device is signed in as the person the title came from.
    func mismatch(with account: AccountStore.Account?) -> Mismatch? {
        guard let account else { return .notSignedIn }
        if account.serverId != signIn.serverId { return .otherServer(account) }
        if account.userId != signIn.userId { return .otherUser(account) }
        return nil
    }

    static func title(for mismatch: Mismatch) -> String {
        switch mismatch {
        case .notSignedIn: "Sign In to Continue"
        case .otherServer: "Signed In to Another Server"
        case .otherUser: "Signed In as Someone Else"
        }
    }

    /// The title's owner, as a link names them.
    var owner: AppLink.Owner {
        AppLink.Owner(serverId: signIn.serverId, userId: signIn.userId)
    }

    /// Says where the title is from, where this device is signed in, and what using the title's
    /// sign-in does: switching to it when it's kept here (`isKept`), adding it otherwise. Neither
    /// signs anyone out.
    func explanation(for mismatch: Mismatch, isKept: Bool, on device: String) -> String {
        let from = "“\(link.name)” is from \(signIn.serverTitle), signed in as \(signIn.userName)."
        func using(keeping current: String) -> String {
            isKept ? "Switching needs no password, and \(current) stays signed in to switch back to."
                : "Adding \(signIn.userName) keeps \(current) signed in to switch back to."
        }
        switch mismatch {
        case .notSignedIn:
            let here = "This \(device) isn't signed in."
            return isKept ? "\(from) \(here) \(signIn.userName)'s sign-in is kept on it, so switching needs no password." : "\(from) \(here)"
        case .otherServer(let account):
            return "\(from) This \(device) is using \(account.serverTitle) as \(account.userName). "
                + using(keeping: "\(account.userName) on \(account.serverTitle)")
        case .otherUser(let account):
            return "\(from) This \(device) is using it as \(account.userName). " + using(keeping: account.userName)
        }
    }

    /// The button that uses the sign-in the title is from: switches to it when it's kept here
    /// (`isKept`), and otherwise signs in to it beside the one in use.
    func signInTitle(for mismatch: Mismatch, isKept: Bool) -> String {
        let onServer = "\(signIn.userName) on \(signIn.serverTitle)"
        switch (mismatch, isKept) {
        case (.notSignedIn, true), (.otherUser, true): return "Switch to \(signIn.userName)"
        case (.otherServer, true): return "Switch to \(onServer)"
        case (.notSignedIn, false): return "Sign In as \(onServer)"
        case (.otherServer, false): return "Add \(onServer)"
        case (.otherUser, false): return "Add \(signIn.userName)"
        }
    }
}

extension View {
    /// Offers the title's page to the person's other devices while it's on screen and the player
    /// doesn't cover it, and tells the player whose page is on screen, which the end of a title
    /// leads back to. Apple TV has no Handoff.
    func handoffPage(_ item: JellyfinItem) -> some View {
        #if os(tvOS)
        modifier(TitlePageOnScreen(itemId: item.id))
        #else
        modifier(TitlePageOnScreen(itemId: item.id))
            .modifier(PageHandoff(item: item))
        #endif
    }

    #if !os(tvOS)
    /// Offers the playback to the person's other devices, at the position it has reached.
    func handoffPlayback(_ model: PlayerModel) -> some View {
        modifier(PlaybackHandoff(model: model))
    }
    #endif

    /// Opens each title `request` asks for under the sign-in it's from: at once when that's the
    /// one in use; after switching to it when it's kept here, which a title handed off from
    /// another device asks about first; and otherwise after adding it beside the one in use, as
    /// asked. Nobody is signed out. A download whose sign-in isn't kept any more opens under the
    /// one in use, as the Downloads tab shows it. `open` opens a title under the sign-in in use.
    func opensTitlesUnderTheirSignIn(_ request: Binding<TitleFromSignIn?>, open: @escaping (AppLink) -> Void) -> some View {
        modifier(TitlesUnderTheirSignIn(request: request, open: open))
    }
}

/// A title that may be from a sign-in other than the one in use.
nonisolated enum TitleFromSignIn: Equatable, Sendable {
    /// A link that says whose title it is (`AppLink.owner`).
    case link(AppLink)
    #if !os(tvOS)
    /// A title another of the person's devices handed off.
    case handoff(Handoff)
    #endif
}

private struct TitlesUnderTheirSignIn: ViewModifier {
    @Binding var request: TitleFromSignIn?
    let open: (AppLink) -> Void

    @Environment(AccountStore.self) private var accounts
    @Environment(KnownServers.self) private var knownServers
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    /// A title waiting for the sign-in it's from, which its link names, to be in use.
    @State private var waiting: AppLink?
    /// The title whose sign-in to switch to or add, as asked.
    @State private var offer: Handoff?
    @State private var showingOffer = false
    /// The sign-in screen, for the sign-in a title is from.
    @State private var signingIn: ServerSignIn?

    func body(content: Content) -> some View {
        content
            .onChange(of: request, initial: true) { _, request in
                guard let request else { return }
                self.request = nil
                follow(request)
            }
            .alert(offerMismatch.map(Handoff.title) ?? "", isPresented: $showingOffer, presenting: offer) { offer in
                if let mismatch = offerMismatch {
                    Button(offer.signInTitle(for: mismatch, isKept: isKept(offer))) { use(offer) }
                }
                Button("Cancel", role: .cancel) { self.offer = nil }
            } message: { offer in
                Text(offerMismatch.map { offer.explanation(for: $0, isKept: isKept(offer), on: Device.name) } ?? "")
            }
            .sheet(item: $signingIn, onDismiss: {
                if waiting?.owner?.isSignedIn(as: accounts.account) != true { waiting = nil }
            }) { signIn in
                LoginView(offer: signIn, addsAccount: true)
            }
            // Once the title's sign-in is in use, it opens.
            .onChange(of: accounts.account) { _, account in
                guard let waiting, waiting.owner?.isSignedIn(as: account) == true else { return }
                self.waiting = nil
                open(waiting)
            }
    }

    private var offerMismatch: Handoff.Mismatch? {
        offer?.mismatch(with: accounts.account)
    }

    private func isKept(_ offer: Handoff) -> Bool {
        accounts.saved.contains { offer.signIn.isSignedIn(as: $0) }
    }

    private func follow(_ request: TitleFromSignIn) {
        switch request {
        case .link(let link):
            guard let owner = link.owner else { return open(link) }
            switch SignInChoice.choose(for: owner, inUse: accounts.account, kept: accounts.saved) {
            case .inUse:
                open(link)
            case .switchTo(let account):
                switchTo(account, for: link)
            case .add:
                if isOrphanedDownload(link, of: owner) {
                    var unowned = link
                    unowned.owner = nil
                    open(unowned)
                } else if let known = knownServers.signIns.first(where: { $0.isOwner(owner) }) {
                    ask(Handoff(link: link, signIn: known))
                } else {
                    messages.show("“\(link.name)” is from a sign-in that isn't on this \(Device.name) any more. Sign in to its server again to open it.")
                }
            }
        #if !os(tvOS)
        case .handoff(let handoff):
            if handoff.mismatch(with: accounts.account) == nil {
                open(handoff.link)
            } else {
                ask(handoff)
            }
        #endif
        }
    }

    private func ask(_ offer: Handoff) {
        self.offer = offer
        showingOffer = true
    }

    /// Switches to the sign-in the title is from when it's kept here, and otherwise opens the
    /// sign-in screen for it, beside the one in use.
    private func use(_ offer: Handoff) {
        self.offer = nil
        var link = offer.link
        link.owner = offer.owner
        switch SignInChoice.choose(for: offer.owner, inUse: accounts.account, kept: accounts.saved) {
        case .inUse:
            open(link)
        case .switchTo(let account):
            switchTo(account, for: link)
        case .add:
            waiting = link
            signingIn = offer.signIn
        }
    }

    /// Switches to `account` and opens `link` once it's in use, here or as the sign-in's change
    /// comes through, whichever is first. A switch that fails, as when its token is gone, says
    /// why, and the title doesn't wait for a later one.
    private func switchTo(_ account: AccountStore.Account, for link: AppLink) {
        waiting = link
        Task {
            await switchAccount(to: account, accounts: accounts, player: player, messages: messages)
            guard waiting == link else { return }
            waiting = nil
            if link.owner?.isSignedIn(as: accounts.account) == true { open(link) }
        }
    }

    /// A download whose sign-in isn't kept here any more, which still plays from this device.
    private func isOrphanedDownload(_ link: AppLink, of owner: AppLink.Owner) -> Bool {
        #if os(tvOS)
        false
        #else
        downloads.jobs.contains { job in
            (job.itemId == link.itemId || job.seriesId == link.itemId) && job.owner.map(AppLink.Owner.init) == owner
        }
        #endif
    }
}

private extension ServerSignIn {
    /// Whether it's the person a link names as a title's owner.
    func isOwner(_ owner: AppLink.Owner) -> Bool {
        serverId == owner.serverId && userId == owner.userId
    }
}

/// Tells the player which title's page is on screen (`PlayerCoordinator.pageOnScreen`).
private struct TitlePageOnScreen: ViewModifier {
    let itemId: String
    @Environment(PlayerCoordinator.self) private var player
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                player.pageOnScreen = itemId
            }
            .onDisappear {
                isOnScreen = false
                if player.pageOnScreen == itemId { player.pageOnScreen = nil }
            }
            // Another episode picked on the page shows in its place.
            .onChange(of: itemId) { _, id in
                if isOnScreen { player.pageOnScreen = id }
            }
    }
}

#if !os(tvOS)
private struct PageHandoff: ViewModifier {
    let item: JellyfinItem
    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    /// Under a pushed page or in another tab the page isn't on screen, and the one that is offers itself.
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .userActivity(Handoff.activityType, isActive: isOnScreen && session != nil && !player.coversScreens) { activity in
                guard let session else { return }
                Handoff(link: AppLink(.open, item), signIn: ServerSignIn(session.account)).describe(activity)
            }
    }
}

/// The player makes its activity current itself: SwiftUI's `userActivity(_:isActive:_:)` offers
/// nothing from a full-screen cover, which is where the player is on iPhone and iPad. Making it
/// current again every few seconds also carries the position, and puts the playback ahead of a
/// page that another window offers in the meantime.
///
/// The activity also tells Siri what's playing, as the entity it knows the title by, and teaches
/// it what the person watches: the intent that plays the title again is donated as it starts
/// (`PlaybackDonation`), and on iPhone, iPad and Vision Pro, where the system predicts from
/// activities, the activity is eligible for prediction. `SignInSurfaces` forgets both when the
/// sign-in in use changes.
private struct PlaybackHandoff: ViewModifier {
    let model: PlayerModel
    @Environment(\.session) private var session

    /// The title on offer: none once it has ended, which another device would only start over.
    private var offered: JellyfinItem? {
        model.status == .ended ? nil : model.item
    }

    func body(content: Content) -> some View {
        content
            .task(id: offered?.id) {
                guard let item = offered, let session else { return }
                PlaybackDonation.donate(item, session: session)
                let activity = NSUserActivity(activityType: Handoff.activityType)
                defer { activity.invalidate() }
                while !Task.isCancelled {
                    Handoff(link: AppLink(.play, item, position: model.clock.time), signIn: ServerSignIn(session.account))
                        .describe(activity)
                    #if !os(macOS)
                    activity.isEligibleForPrediction = true
                    #endif
                    activity.appEntityIdentifier = EntityIdentifier.title(item)
                    activity.becomeCurrent()
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                }
            }
    }
}
#endif
