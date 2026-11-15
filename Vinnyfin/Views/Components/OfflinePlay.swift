import SwiftUI

/// Whether a title plays now. Any does while the server answers, or hasn't been asked yet. While
/// it's out of reach, only one with a finished download whose file is on this device does: a
/// show doesn't, as the server picks which of its episodes plays.
nonisolated enum PlayAvailability {
    /// `isDownloaded` says whether the item (that version of it, given one) has a download here.
    static func canPlay(_ item: JellyfinItem, mediaSourceId: String? = nil, isServerOutOfReach: Bool,
                        isDownloaded: (_ itemId: String, _ mediaSourceId: String?) -> Bool) -> Bool {
        guard isServerOutOfReach else { return true }
        guard !item.isSeries else { return false }
        return isDownloaded(item.id, mediaSourceId)
    }
}

extension View {
    /// Turns off a control that plays `item`, or the version `mediaSourceId` of it, while the
    /// server is out of reach and it isn't downloaded, and says why to VoiceOver and, on the Mac,
    /// under the pointer. For a show, pass the episode the control plays, when it's known.
    /// `dimming` fades a control whose style doesn't show it's off, as an artwork card's doesn't.
    func playableOffline(_ item: JellyfinItem, mediaSourceId: String? = nil, dimming: Bool = false) -> some View {
        modifier(OfflinePlayability(item: item, mediaSourceId: mediaSourceId, dims: dimming))
    }
}

struct OfflinePlayability: ViewModifier {
    let item: JellyfinItem
    let mediaSourceId: String?
    let dims: Bool
    /// Whether the item has a download here; nil asks the app's downloads.
    var isDownloaded: ((_ itemId: String, _ mediaSourceId: String?) -> Bool)?
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.session) private var session
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads: DownloadManager?
    #endif

    func body(content: Content) -> some View {
        if isPlayable {
            content
        } else {
            content
                .disabled(true)
                .opacity(dims ? 0.45 : 1)
                .accessibilityHint(reason)
                .help(reason)
        }
    }

    private var isPlayable: Bool {
        PlayAvailability.canPlay(item, mediaSourceId: mediaSourceId, isServerOutOfReach: reachability.isOutOfReach) { itemId, sourceId in
            if let isDownloaded { return isDownloaded(itemId, sourceId) }
            #if os(tvOS)
            return false
            #else
            return downloads?.playableFile(itemId: itemId, mediaSourceId: sourceId) != nil
            #endif
        }
    }

    /// "Can't reach Showcase. Download it to watch it offline."
    private var reason: String {
        let server = "Can't reach \(session?.account.serverTitle ?? "the server")."
        #if os(tvOS)
        return server
        #else
        return item.isSeries ? server : server + " Download it to watch it offline."
        #endif
    }
}
