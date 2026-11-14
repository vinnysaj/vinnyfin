import AetherEngine
import AVFoundation
import Combine
import NukeUI
import SwiftUI

/// The title's picture, dimmed, in place of the video: an episode's still, else the backdrop,
/// with what's going on along the bottom, clear of what covers it there. It stands in while a
/// title starts, until its first frame, and while AirPlay plays the video on another screen.
struct PlayerBackdrop<Caption: View>: View {
    let item: JellyfinItem?
    /// Where what covers the bottom of the screen starts in global coordinates: the controls'
    /// bottom bar while they show, or the up-next card.
    var coveredBelow: CGFloat?
    @ViewBuilder var caption: Caption

    @Environment(\.session) private var session
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        ZStack {
            Color.black
                .overlay {
                    // Black until the picture is in, rather than `Artwork`'s placeholder.
                    LazyImage(url: pictureURL, transaction: Transaction(animation: .easeOut(duration: 0.3))) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .opacity(0.45)
                    .accessibilityIgnoresInvertColors()
                }
                .clipped()
                .ignoresSafeArea()
            GeometryReader { geometry in
                caption
                    .padding(.horizontal, Metrics.playerInset)
                    .padding(.bottom, PlayerLayout.bottomPadding(containerMaxY: geometry.frame(in: .global).maxY,
                                                                 bottomBarTop: coveredBelow))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(false)
    }

    private var pictureURL: URL? {
        guard let item else { return nil }
        #if !os(tvOS)
        if session == nil || !downloads.isNetworkReachable,
           let saved = downloads.artworkURL(itemId: item.id, kind: item.isEpisode ? .primary : .backdrop) {
            return saved
        }
        #endif
        guard let session else { return nil }
        return item.isEpisode ? session.landscape(item, width: 1280) : session.backdrop(item, width: 1920) ?? session.landscape(item, width: 1280)
    }
}

/// What starts: the title's logo, or its name, and for an episode which one it is. Where the
/// controls leave little height under the transport, the logo is smaller, and beside the words.
struct StartingTitle: View {
    let item: JellyfinItem
    var isShort = false

    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        let layout = isShort
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        layout {
            if let logoURL {
                // At its leading edge, in line with the words beside or under it.
                LazyImage(url: logoURL) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxWidth: isShort ? Self.logoWidth / 2 : Self.logoWidth, maxHeight: isShort ? Self.logoHeight / 2 : Self.logoHeight,
                       alignment: .bottomLeading)
                .accessibilityIgnoresInvertColors()
            } else {
                Text(name)
                    .font((isShort ? Font.title3 : .title).weight(.bold))
                    .lineLimit(isShort ? 1 : dynamicTypeSize.lineLimit(2))
            }
            if item.isEpisode {
                Text([item.episodeCode, item.name].compactMap(\.self).joined(separator: " · "))
                    .font((isShort ? Font.headline : .title3).weight(.semibold))
                    .lineLimit(isShort ? 1 : dynamicTypeSize.lineLimit(2))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting \(item.isEpisode ? [name, item.episodeCode, item.name].compactMap(\.self).joined(separator: ", ") : name)")
    }

    /// The show's name for an episode.
    private var name: String { item.isEpisode ? item.seriesName ?? item.name : item.name }

    private var logoURL: URL? {
        #if !os(tvOS)
        if session == nil || !downloads.isNetworkReachable, let saved = downloads.artworkURL(itemId: item.id, kind: .logo) {
            return saved
        }
        #endif
        return session?.logo(item, width: 900)
    }

    private static var logoWidth: CGFloat {
        #if os(tvOS)
        560
        #else
        300
        #endif
    }

    private static var logoHeight: CGFloat {
        #if os(tvOS)
        160
        #else
        90
        #endif
    }
}

#if os(iOS) || os(macOS)
/// Where AirPlay takes the playback: whether another screen has the picture, by its name, and
/// whether the sound went to one without the picture, which this video can't send.
@Observable
final class ExternalPlayback {
    /// A receiver shows the picture, so this screen has none.
    private(set) var isActive = false
    /// The receiver's name, as Control Center shows it; nil where the system doesn't say.
    private(set) var routeName: String?
    /// The sound plays on a receiver while the picture stays here (`AetherEngine.airPlayPictureStaysLocal`).
    private(set) var pictureStaysLocal = false
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()

    func follow(_ engine: AetherEngine) {
        guard subscriptions.isEmpty else { return }
        engine.$currentAVPlayer
            .map { player -> AnyPublisher<Bool, Never> in
                guard let player else { return Just(false).eraseToAnyPublisher() }
                return player.publisher(for: \.isExternalPlaybackActive).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                self?.isActive = active
                self?.readRoute()
            }
            .store(in: &subscriptions)
        engine.$airPlayPictureStaysLocal
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] local in
                self?.pictureStaysLocal = local
                self?.readRoute()
            }
            .store(in: &subscriptions)
        #if os(iOS)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.readRoute() }
            .store(in: &subscriptions)
        #endif
    }

    private func readRoute() {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        routeName = (outputs.first { $0.portType == .airPlay } ?? outputs.first)?.portName
        #endif
    }

    /// "Living Room", or what to call a receiver without a name.
    var receiverName: String { routeName ?? "AirPlay" }
}

/// That AirPlay plays the video on another screen, over the title's picture.
struct AirPlayCaption: View {
    let receiverName: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Playing on \(receiverName)")
                    .font(.title3.weight(.semibold))
                Text("The controls here work as its remote.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "airplay.video")
                .font(.title)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.airPlay")
    }
}

/// That only the sound went to an AirPlay receiver, below the controls' top bar while they show,
/// for a few seconds.
struct AirPlaySoundOnlyNotice: View {
    let receiverName: String
    /// The bottom of the controls' top bar in global coordinates while they show.
    var controlsBottom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let clearBelow = controlsBottom.map { max(0, $0 - geometry.frame(in: .global).minY) } ?? 0
            Label(Self.message(receiverName), systemImage: "airplay.audio")
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .platformGlass(in: .capsule)
                .padding(.top, clearBelow + 12)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Metrics.playerInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.airPlaySoundOnly")
    }

    static func message(_ receiverName: String) -> String {
        "Only the sound plays on \(receiverName). This video's picture can't go over AirPlay, so it stays on this \(Device.name)."
    }
}
#endif
