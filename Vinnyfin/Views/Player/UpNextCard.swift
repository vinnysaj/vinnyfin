import SwiftUI

/// The card offering the next episode as one ends (`UpNextPhase`): in the credits the server
/// marks, in the last half minute, and once it has ended. With autoplay it counts down, from the
/// start of the credits or from the end, as a ring filling on Play Now. Its other button keeps
/// the credits, hides it, or plays the episode again. On Apple TV, with the controls hidden, a
/// click on the picture plays it from the credits or the end; in the last half minute the click
/// only brings up the controls, with Play Now ready (`PlayerView.pictureClicked`).
struct UpNextCard: View {
    let model: PlayerModel
    let episode: JellyfinItem
    let phase: UpNextPhase
    #if os(tvOS)
    let focus: FocusState<PlayerFocus?>.Binding
    /// Focus stays on the picture, where only a click and Back reach the card.
    let controlsHidden: Bool
    private let layout = Layout.tv
    #else
    /// From `PlayerLayout.upNextCardWidth(containerWidth:)`.
    let width: CGFloat
    private var layout: Layout { Layout(width: width) }
    #endif
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        AdaptiveStack(spacing: layout.spacing) {
            // At the accessibility text sizes the words take the room.
            if !dynamicTypeSize.isAccessibilitySize {
                Artwork(url: session?.landscape(episode, width: layout.artworkPixels), aspectRatio: 16.0 / 9.0,
                        cornerRadius: layout.artworkRadius, placeholder: "play.rectangle")
                    .frame(width: layout.artworkWidth)
            }
            VStack(alignment: .leading, spacing: layout.lineSpacing) {
                if let countdown = model.upNextCountdown {
                    Text("Next Episode in \(countdown.remaining)")
                        .font(layout.countdownFont)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: countdown.remaining)
                } else {
                    Text("Up Next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text([episode.episodeCode, episode.name].compactMap(\.self).joined(separator: " · "))
                    .font(layout.titleFont)
                    .lineLimit(dynamicTypeSize.lineLimit(2))
                buttons
                    .controlSize(layout.buttonSize)
                    // Each button's words on one line: squeezed, they'd wrap a word or a letter a line.
                    .lineLimit(1)
                    #if os(tvOS)
                    .fixedSize()
                    .padding(.top, 8)
                    #endif
            }
        }
        .padding(layout.padding)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? max(640, layout.width) : layout.width, alignment: .leading)
        .platformGlass(in: .rect(cornerRadius: layout.radius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.upNext")
    }

    #if os(tvOS)
    @ViewBuilder private var buttons: some View {
        AdaptiveStack {
            PlayNowButton(model: model, episode: episode)
                .modifier(ClickTarget(isTarget: controlsHidden && phase != .nearEnd))
                .focused(focus, equals: .action)
            if controlsHidden {
                // Focus stays on the picture, where the other button can't be reached.
                if let hint = backHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                secondaryButton
                    .focused(focus, equals: .hideUpNext)
            }
        }
    }
    #else
    /// Side by side where they fit, as Play Now and Hide do on a phone; else, as Play Now with
    /// its countdown and Watch Again on a phone, one above the other.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                PlayNowButton(model: model, episode: episode)
                secondaryButton
            }
            VStack(alignment: .leading) {
                PlayNowButton(model: model, episode: episode)
                secondaryButton
            }
        }
    }
    #endif

    /// Keeps the credits, hides the card, or once the episode has ended, plays it again.
    @ViewBuilder private var secondaryButton: some View {
        switch phase {
        case .credits:
            Button("Watch Credits") { model.cancelUpNext() }
                .buttonStyle(.platformGlass)
                .accessibilityIdentifier("player.watchCredits")
        case .nearEnd:
            Button("Hide") { model.cancelUpNext() }
                .buttonStyle(.platformGlass)
                .accessibilityIdentifier("player.hideUpNext")
        case .ended:
            Button("Watch Again") { model.watchAgain() }
                .buttonStyle(.platformGlass)
                .accessibilityIdentifier("player.watchAgain")
        }
    }

    #if os(tvOS)
    /// What Back does with the controls hidden.
    private var backHint: String? {
        switch phase {
        case .credits: "Press Back to Watch Credits"
        case .nearEnd: "Press Back to Hide"
        case .ended: model.upNextCountdown != nil ? "Press Back to Stop" : nil
        }
    }
    #endif

    /// The phone's card is 440 points wide; a wider screen's is larger in proportion, its title
    /// and buttons too. Apple TV's text is about twice the size, seen from across the room, and
    /// so is its card.
    private struct Layout {
        let width: CGFloat
        let artworkWidth: CGFloat
        let artworkRadius: CGFloat
        let spacing: CGFloat
        let lineSpacing: CGFloat
        let padding: CGFloat
        let radius: CGFloat
        let buttonSize: ControlSize
        let titleFont: Font
        let countdownFont: Font

        var artworkPixels: Int { Int(artworkWidth * 3) }

        #if os(tvOS)
        static let tv = Layout(width: 920, artworkWidth: 320, artworkRadius: 16, spacing: 28, lineSpacing: 6, padding: 24,
                               radius: 36, buttonSize: .regular, titleFont: .subheadline.weight(.semibold),
                               countdownFont: .headline)
        #else
        init(width: CGFloat) {
            let isLarge = width >= 500
            self.width = width
            artworkWidth = (width * 0.34).rounded()
            artworkRadius = isLarge ? 12 : 8
            spacing = isLarge ? 18 : 14
            lineSpacing = isLarge ? 6 : 4
            padding = isLarge ? 16 : 12
            radius = isLarge ? 26 : 20
            buttonSize = isLarge ? .regular : .small
            titleFont = (isLarge ? Font.headline : .subheadline).weight(.semibold)
            countdownFont = (isLarge ? Font.title3 : .headline).weight(.bold)
        }
        #endif
    }
}

/// Plays the next episode, its countdown as a ring filling around the seconds left.
private struct PlayNowButton: View {
    let model: PlayerModel
    let episode: JellyfinItem

    var body: some View {
        Button {
            Task { await model.play(episode) }
        } label: {
            Label {
                Text("Play Now")
            } icon: {
                if let countdown = model.upNextCountdown {
                    CountdownRing(countdown: countdown)
                } else {
                    Image(systemName: "play.fill")
                }
            }
        }
        .buttonStyle(.platformGlassProminent)
        .accessibilityLabel("Play Now")
        .accessibilityValue(model.upNextCountdown.map { "Starts in \($0.remaining) seconds" } ?? "")
        .accessibilityIdentifier("player.playNext")
    }
}

/// How much of the countdown to the next episode has run, as a ring filling around the seconds
/// left, each second's share filling as it passes.
struct CountdownRing: View {
    let countdown: UpNextCountdown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// About the height of the button's words: Apple TV's are half again as large.
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = Self.baseSide

    private static var baseSide: CGFloat {
        #if os(tvOS)
        32
        #else
        20
        #endif
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: side / 9)
            Circle()
                .trim(from: 0, to: countdown.progress)
                .stroke(style: StrokeStyle(lineWidth: side / 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: countdown.progress)
            Text("\(countdown.remaining)")
                .font(.system(size: side * 0.55, weight: .bold).monospacedDigit())
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The up-next card as a slim button just above the timeline, where the controls leave no room
/// for the card under the transport: what's next and, counting down, how soon. It plays it; the
/// card, with its other button, comes back as the controls go.
struct UpNextPill: View {
    let model: PlayerModel
    let episode: JellyfinItem

    var body: some View {
        Button {
            Task { await model.play(episode) }
        } label: {
            Label {
                let when = Text(model.upNextCountdown.map { "Next in \($0.remaining)" } ?? "Up Next").fontWeight(.bold).monospacedDigit()
                let what = Text([episode.episodeCode, episode.name].compactMap(\.self).joined(separator: " · ")).fontWeight(.regular)
                Text("\(when)  \(what)")
            } icon: {
                if let countdown = model.upNextCountdown {
                    CountdownRing(countdown: countdown)
                } else {
                    Image(systemName: "play.fill")
                }
            }
            .lineLimit(1)
        }
        .buttonStyle(.platformGlassProminent)
        .accessibilityLabel("Play Next Episode")
        .accessibilityValue([model.upNextCountdown.map { "Starts in \($0.remaining) seconds" }, episode.episodeCode, episode.name]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("player.playNext")
    }
}

/// In place of the countdown, after episodes that started by themselves with nobody doing
/// anything (`UnattendedAutoplay`): the playback waits, paused, to hear that someone is still
/// watching. Continue Watching plays the next episode; Stop closes the player.
struct StillWatchingCard: View {
    let model: PlayerModel
    let onStop: () -> Void
    #if os(tvOS)
    let focus: FocusState<PlayerFocus?>.Binding
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            AdaptiveStack(spacing: 12) {
                Button("Continue Watching") { Task { await model.continueWatching() } }
                    .buttonStyle(.platformGlassProminent)
                    #if os(tvOS)
                    .focused(focus, equals: .action)
                    #endif
                    .accessibilityIdentifier("player.continueWatching")
                Button("Stop", action: onStop)
                    .buttonStyle(.platformGlass)
                    #if os(tvOS)
                    .focused(focus, equals: .hideUpNext)
                    #endif
                    .accessibilityIdentifier("player.stopWatching")
            }
            #if os(tvOS)
            .lineLimit(1)
            .fixedSize()
            #endif
        }
        .padding(20)
        .platformGlass(in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.stillWatching")
    }

    private var question: String {
        guard let show = model.item?.seriesName, !show.isEmpty else { return "Still Watching?" }
        return "Still watching \(show)?"
    }
}

/// Says the player resumed, or skipped the intro, with the way back as its button: Start Over,
/// or Watch It.
struct PlaybackChipButton: View {
    let model: PlayerModel
    let chip: PlaybackChip

    var body: some View {
        Button {
            switch chip {
            case .resumed: model.startOver()
            case .skippedIntro: model.watchIntro()
            }
        } label: {
            HStack(spacing: 8) {
                Text(said).foregroundStyle(.secondary)
                Text(action).fontWeight(.semibold)
            }
            .lineLimit(1)
        }
        .buttonStyle(.platformGlass)
        .accessibilityLabel(action)
        .accessibilityHint(said)
        .accessibilityIdentifier("player.chip")
    }

    private var said: String {
        switch chip {
        case .resumed(let position): "Resumed at \(Scrubber.format(position))"
        case .skippedIntro: "Intro Skipped"
        }
    }

    private var action: String {
        switch chip {
        case .resumed: "Start Over"
        case .skippedIntro: "Watch It"
        }
    }
}

#if os(tvOS)
/// The skip button or the up-next card's Play Now while a click on the picture takes it, with the
/// controls hidden: white, as a button with focus is, though focus stays on the picture.
struct ClickTarget: ViewModifier {
    let isTarget: Bool

    func body(content: Content) -> some View {
        if isTarget {
            content
                .tint(.white)
                .foregroundStyle(.black)
        } else {
            content
        }
    }
}
#endif
