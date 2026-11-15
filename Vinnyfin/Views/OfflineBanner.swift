import SwiftUI

/// Over every screen while the server is out of reach: "Offline", over what shows meanwhile (on
/// devices that download, the downloads) and why, as much of that as fits on its line; and Try
/// Again, which asks the server again. VoiceOver hears it all. On Apple TV, where it can't take
/// focus, the server is asked again on its own.
struct OfflineBanner: View {
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.session) private var session
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif
    /// Try Again was pressed, and the server hasn't answered yet.
    @State private var isTryingAgain = false

    var body: some View {
        let words = Words(showsDownloads: showsDownloads, absence: absence, server: session?.account.serverTitle)
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(words.title)
                    .font(.subheadline.weight(.semibold))
                if !isCompact {
                    // The whole of it where there's room; else what shows, or why, said shorter.
                    ViewThatFits(in: .horizontal) {
                        Text(words.detail)
                        Text(words.shortDetail)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(words.spoken)
            #if !os(tvOS)
            Spacer(minLength: 0)
            if !isCompact { retry }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline.banner")
    }

    /// The banner's words: "Offline", over what shows and why.
    struct Words: Equatable {
        let title = "Offline"
        /// "Showing your downloads · Can't reach Showcase."
        let detail: String
        /// Where `detail` doesn't fit: "Showing your downloads", or "Can't reach the server."
        let shortDetail: String
        /// "Offline: showing your downloads. Can't reach Showcase."
        let spoken: String

        init(showsDownloads: Bool, absence: ServerReachability.Absence?, server: String?) {
            let why: String
            let shortWhy: String
            if absence == .deviceOffline {
                why = "This \(Device.name) isn't connected to the internet."
                shortWhy = "No internet connection."
            } else {
                why = "Can't reach \(server ?? "the server")."
                shortWhy = "Can't reach the server."
            }
            if showsDownloads {
                detail = "Showing your downloads · \(why)"
                shortDetail = "Showing your downloads"
                spoken = "Offline: showing your downloads. \(why)"
            } else {
                detail = why
                shortDetail = shortWhy
                spoken = "Offline. \(why)"
            }
        }
    }

    /// Whether the sign-in has downloads to show in place of the server's titles.
    private var showsDownloads: Bool {
        #if os(tvOS)
        false
        #else
        !OfflineDownloads.titles(downloads.jobs, of: session?.account) { _ in nil }.isEmpty
        #endif
    }

    private var absence: ServerReachability.Absence? {
        if case .outOfReach(let absence) = reachability.state { absence } else { nil }
    }

    /// The tab bar's accessory inline with the tab bar, as it is on iPhone scrolled down: room for
    /// "Offline" alone.
    private var isCompact: Bool {
        #if os(iOS)
        placement == .inline
        #else
        false
        #endif
    }

    #if !os(tvOS)
    @ViewBuilder private var retry: some View {
        if isTryingAgain {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Trying again")
        } else {
            Button("Try Again", systemImage: "arrow.clockwise") {
                isTryingAgain = true
                Task {
                    await reachability.check()
                    isTryingAgain = false
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.title3)
            .help("Try Again")
            .accessibilityIdentifier("offline.retry")
        }
    }
    #endif
}
