import SwiftUI

/// Over every screen while the server is out of reach: that the app is offline, showing what was
/// saved, and on devices that download, that downloads still play; why; and Try Again, which asks
/// the server again. On Apple TV, where it can't take focus, the server is asked again on its own.
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
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if !isCompact {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            #if !os(tvOS)
            Spacer(minLength: 0)
            if !isCompact { retry }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline.banner")
    }

    /// "Offline: showing your downloads", or "Offline" with none to show, or no room to say so.
    private var title: String {
        #if os(tvOS)
        "Offline"
        #else
        isCompact || OfflineDownloads.titles(downloads.jobs, of: session?.account) { _ in nil }.isEmpty
            ? "Offline" : "Offline: showing your downloads"
        #endif
    }

    /// "Can't reach Showcase."
    private var explanation: String {
        let server = session?.account.serverTitle ?? "the server"
        if case .outOfReach(.deviceOffline) = reachability.state {
            return "This \(Device.name) isn't connected to the internet."
        }
        return "Can't reach \(server)."
    }

    /// The tab bar's accessory inline with the tab bar, as it is on iPhone scrolled down.
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
