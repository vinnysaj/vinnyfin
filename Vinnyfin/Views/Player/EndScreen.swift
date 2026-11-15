import SwiftUI

/// The end of a movie, or of a show's last episode, over its dimmed last frame: the way back to
/// its page (or its show's), the title again, and titles like it. On Apple TV, left alone for
/// `idleReturn`, it goes back to the page by itself. Elsewhere a tap beside it brings back the
/// controls, to move back into the last scene.
struct EndScreen: View {
    let model: PlayerModel
    let item: JellyfinItem
    /// Closes the player on a title's page.
    let onReturn: (JellyfinItem) -> Void
    #if os(tvOS)
    let focus: FocusState<PlayerFocus?>.Binding
    #else
    let onClose: () -> Void
    let onShowControls: () -> Void
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(tvOS)
    /// Counts the remote's moves, each of which starts the wait for `idleReturn` over.
    @State private var moves = 0
    #endif

    /// How long Apple TV waits on the end screen with nothing pressed before it goes back to the
    /// title's page.
    static let idleReturn: Duration = .seconds(20)

    private var way: EndScreenReturn { EndScreenReturn(for: item) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    #if !os(tvOS)
                    .contentShape(.rect)
                    .onTapGesture(perform: onShowControls)
                    .accessibilityHidden(true)
                    #endif
                // Below the close button: the posters as on the browsing screens where there's
                // room, smaller where the screen is short, as an iPhone on its side is, else none.
                ViewThatFits(in: .vertical) {
                    content(posters: .init(width: Metrics.posterWidth, showsTitles: geometry.size.height > 520))
                    content(posters: .init(width: Self.smallPosterWidth, showsTitles: false))
                    content(posters: nil)
                }
                .padding(.horizontal, Metrics.playerInset)
                .padding(.top, Self.topInset)
                .padding(.bottom, Self.bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                #if !os(tvOS)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.platformGlass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("player.close")
                .padding(.horizontal, Metrics.playerInset)
                .padding(.vertical, 12)
                #if os(iOS)
                // Beside an iPad window's own buttons, as the controls' Close is.
                .containerCornerOffset(.leading, sizeToFit: true)
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                #endif
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.endScreen")
        #if os(tvOS)
        .onMoveCommand { _ in moves += 1 }
        .onChange(of: focus.wrappedValue) { moves += 1 }
        .task(id: moves) {
            try? await Task.sleep(for: Self.idleReturn)
            guard !Task.isCancelled else { return }
            onReturn(way.page)
        }
        #endif
    }

    /// How the titles like this one show.
    private struct Posters {
        let width: CGFloat
        let showsTitles: Bool
    }

    private func content(posters: Posters?) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            VStack(alignment: .leading, spacing: 4) {
                if let show = item.seriesName, item.isEpisode {
                    Text([show, item.episodeCode].compactMap(\.self).joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(item.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(dynamicTypeSize.lineLimit(2))
                    .accessibilityAddTraits(.isHeader)
            }
            // Each button's words on one line: side by side where they fit, else one above the other.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(alignment: .leading, spacing: 12) { buttons }
            }
            .controlSize(.large)
            .lineLimit(1)
            if let posters, !model.similarTitles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More Like This")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Self.posterSpacing) {
                            ForEach(model.similarTitles) { other in
                                Button {
                                    onReturn(other)
                                } label: {
                                    PosterCard(item: other, showsTitle: posters.showsTitles)
                                }
                                .buttonStyle(.artwork)
                                .frame(width: posters.width)
                            }
                        }
                        #if os(tvOS)
                        // Room for a focused poster to lift.
                        .padding(.vertical, 20)
                        #endif
                    }
                    .scrollClipDisabled()
                    .scrollIndicators(.hidden)
                    // As tall as its posters: given the screen's height, it would take it all and
                    // push the rest up off the bottom.
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(tvOS)
                    .focusSection()
                    #endif
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.similarTitles.isEmpty)
    }

    /// Back to the page, first and with focus on Apple TV, then Watch Again.
    @ViewBuilder private var buttons: some View {
        Button {
            onReturn(way.page)
        } label: {
            Label(way.label, systemImage: item.isEpisode ? "tv" : "info.circle")
        }
        .buttonStyle(.platformGlassProminent)
        #if os(tvOS)
        .focused(focus, equals: .action)
        #endif
        .accessibilityIdentifier("player.endScreen.return")
        Button {
            model.watchAgain()
        } label: {
            Label("Watch Again", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.platformGlass)
        .accessibilityIdentifier("player.watchAgain")
    }

    private static let smallPosterWidth: CGFloat = 72

    /// Clear of the close button along the top; on Apple TV, which has none, the screen's margin.
    private static var topInset: CGFloat {
        #if os(tvOS)
        60
        #else
        76
        #endif
    }

    private static var spacing: CGFloat {
        #if os(tvOS)
        32
        #else
        16
        #endif
    }

    private static var posterSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        12
        #endif
    }

    private static var bottomInset: CGFloat {
        #if os(tvOS)
        60
        #else
        24
        #endif
    }
}
