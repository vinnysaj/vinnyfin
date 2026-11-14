import SwiftUI
import UniformTypeIdentifiers

/// The first screen without a server: connect to one, or just play a file from this device.
struct WelcomeView: View {
    @Environment(PlayerCoordinator.self) private var player
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var connecting = false
    @State private var importing = false
    @State private var showingDownloads = false
    #endif

    var body: some View {
        #if os(tvOS)
        LoginView()
        #else
        // Centred on the screen, and scrolling once larger text makes it taller.
        GeometryReader { screen in
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "play.square.stack.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("vinnyfin").font(.largeTitle.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Your Jellyfin library, and every video on this \(Device.name), in every format.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 420)
                    }
                    VStack(spacing: 12) {
                        Button {
                            connecting = true
                        } label: {
                            buttonLabel("Connect to Jellyfin")
                        }
                        .buttonStyle(.platformGlassProminent)
                        .accessibilityIdentifier("welcome.connect")
                        Button {
                            importing = true
                        } label: {
                            buttonLabel("Play a Video File")
                        }
                        .buttonStyle(.platformGlass)
                        .accessibilityIdentifier("welcome.openFile")
                        if !downloads.jobs.isEmpty {
                            Button {
                                showingDownloads = true
                            } label: {
                                buttonLabel("Downloads")
                            }
                            .buttonStyle(.platformGlass)
                        }
                    }
                    .controlSize(.large)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: screen.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(isPresented: $connecting) { LoginView() }
        .sheet(isPresented: $showingDownloads) { DownloadsView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: DownloadsView.videoTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            player.playFile(url)
        }
        #endif
    }

    #if !os(tvOS)
    /// A button's title, wrapping rather than cut short, as wide as the screen at the
    /// accessibility sizes.
    private func buttonLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 280)
    }
    #endif
}
