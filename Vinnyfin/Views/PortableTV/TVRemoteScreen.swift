#if os(iOS)
import SwiftUI
import UIKit

/// This iPhone or iPad as a TV's remote, laid out as Apple TV's remote in Control Center: the TV
/// picked at the top beside its power button, a touch surface to swipe and tap through the
/// library (on YouTube a trackpad), and below it Back, play and pause and Home, then skipping and
/// Search, then the volume.
struct TVRemoteScreen: View {
    @Environment(TVRemote.self) private var remote
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @State private var asksToSleep = false

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let target = remote.target, target.sleeps {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Sleep", systemImage: "power") { asksToSleep = true }
                                .accessibilityIdentifier("tvRemote.sleep")
                                .confirmationDialog("Put \(target.name) to Sleep?", isPresented: $asksToSleep, titleVisibility: .visible) {
                                    Button("Sleep") { remote.press(.sleep) }
                                } message: {
                                    Text("vinnyfin closes there, stopping what plays, and the Mac goes to sleep.")
                                }
                        }
                    }
                    ToolbarItem(placement: .principal) { picker }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("tvRemote.done")
                    }
                }
        }
        .task { await remote.run() }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
    }

    @ViewBuilder private var content: some View {
        if accounts.session == nil {
            ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.exclamationmark",
                                   description: Text("Sign in to your server to use this \(Device.name) as a remote."))
        } else if let target = remote.target {
            TVRemoteControls(target: target)
        } else if !remote.hasLooked {
            ProgressView("Looking for TVs…")
        } else {
            ContentUnavailableView {
                Label("No TVs", systemImage: "tv")
            } description: {
                Text(noTVs)
            }
            .accessibilityIdentifier("tvRemote.none")
        }
    }

    private var noTVs: String {
        var text = "On your Mac, open vinnyfin and click Portable TV on Home. It shows up here while it's signed in to \(accounts.account?.serverName ?? "your server") as you."
        if let problem = remote.problem { text += "\n\n\(problem)" }
        return text
    }

    /// The TV's name, which picks another, as at the top of Apple TV's remote.
    private var picker: some View {
        Menu {
            Picker("TV", selection: Binding(get: { remote.target?.session.deviceId }, set: { remote.chosenDeviceId = $0 })) {
                ForEach(remote.televisions) { tv in
                    Label(tv.name, systemImage: tv.symbol).tag(Optional(tv.session.deviceId))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(remote.target?.name ?? "Remote").font(.headline).lineLimit(1)
                if !remote.televisions.isEmpty {
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
        .disabled(remote.televisions.isEmpty)
        .accessibilityLabel("TV")
        .accessibilityValue(remote.target?.name ?? "None")
        .accessibilityIdentifier("tvRemote.picker")
    }
}

/// The remote for one TV.
private struct TVRemoteControls: View {
    let target: PlayTarget
    @Environment(TVRemote.self) private var remote
    @State private var isTyping = false
    @State private var text = ""
    @FocusState private var fieldHasFocus: Bool

    var body: some View {
        let space = remote.space
        VStack(spacing: 16) {
            if target.hasYouTube {
                Picker("Show", selection: Binding(get: { remote.space }, set: { remote.show($0) })) {
                    Text("Library").tag(TVSpace.library)
                    Text("YouTube").tag(TVSpace.youTube)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tvRemote.space")
            }
            if isTyping {
                keyboardField
            } else if space == .library, let item = remote.nowPlaying {
                TVNowPlaying(item: item)
            }
            Group {
                switch space {
                case .library:
                    SwipeSurface { remote.press(.init($0)) } onSelect: { remote.press(.select) }
                case .youTube:
                    TrackpadSurface()
                }
            }
            .frame(maxHeight: .infinity)
            buttons
            if let problem = remote.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: 520)
        .animation(.snappy, value: isTyping)
        .animation(.snappy, value: space)
        // As typed, in the library, whose search finds as it goes; YouTube searches on Search.
        .task(id: text) {
            guard isTyping, space == .library, !text.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            remote.press(.text(text))
        }
    }

    private var keyboardField: some View {
        HStack {
            TextField(remote.space == .youTube ? "Search YouTube" : "Search Your Library", text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .focused($fieldHasFocus)
                .onSubmit {
                    remote.press(.text(text))
                    isTyping = false
                }
                .accessibilityIdentifier("tvRemote.searchField")
            Button("Cancel") { isTyping = false }
                .buttonStyle(.platformGlass)
        }
        .onAppear { fieldHasFocus = true }
    }

    /// Rows of round buttons under the surface, as on Apple TV's remote, the volume's for a TV
    /// that takes them.
    private var buttons: some View {
        Grid(horizontalSpacing: 34, verticalSpacing: 18) {
            GridRow {
                RemoteButton(title: "Back", symbol: "chevron.backward", identifier: "back") { remote.press(.back) }
                RemoteButton(title: "Play or Pause", symbol: "playpause.fill", identifier: "playPause") { remote.playPause() }
                RemoteButton(title: "Home", symbol: "tv", identifier: "home") { remote.press(.home(nil)) }
            }
            GridRow {
                RemoteButton(title: "Back \(Int(RemoteCommand.skipInterval)) Seconds", symbol: "gobackward.10", identifier: "skipBack") {
                    remote.skip(forward: false)
                }
                RemoteButton(title: "Search", symbol: "magnifyingglass", identifier: "search") {
                    text = ""
                    isTyping = true
                    // The TV's search comes up as the keyboard does here.
                    if remote.space == .library { remote.press(.text("")) }
                }
                RemoteButton(title: "Forward \(Int(RemoteCommand.skipInterval)) Seconds", symbol: "goforward.10", identifier: "skipForward") {
                    remote.skip(forward: true)
                }
            }
            if target.takesVolume {
                GridRow {
                    RemoteButton(title: "Volume Down", symbol: "speaker.minus.fill", identifier: "volumeDown") { remote.press(.volumeDown) }
                    RemoteButton(title: "Mute", symbol: "speaker.slash.fill", identifier: "mute") { remote.press(.mute) }
                    RemoteButton(title: "Volume Up", symbol: "speaker.plus.fill", identifier: "volumeUp") { remote.press(.volumeUp) }
                }
            }
        }
    }
}

/// What plays on the TV, with its timeline to scrub.
private struct TVNowPlaying: View {
    let item: JellyfinItem
    @Environment(TVRemote.self) private var remote
    @Environment(\.session) private var session
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Artwork(url: session?.landscape(item, width: 300), aspectRatio: 16.0 / 9.0, cornerRadius: 6)
                    .frame(width: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isEpisode ? item.name : item.titleWithYear).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let subtitle = PlaybackResolver.subtitle(item) {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if remote.duration > 0 {
                // The player's timeline bar, rather than a Slider: a Slider's drag never ends in a sheet.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let time = remote.position(at: context.date)
                    let position = scrubPosition ?? time
                    VStack(spacing: 2) {
                        TimelineBar(time: time, duration: remote.duration, color: .primary, height: scrubPosition == nil ? 5 : 9,
                                    position: $scrubPosition) { remote.seek(to: $0) }
                            .frame(height: 24)
                            .accessibilityElement()
                            .accessibilityLabel("Position")
                            .accessibilityValue(SpokenTime.position(position, of: remote.duration))
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: remote.skip(forward: true)
                                case .decrement: remote.skip(forward: false)
                                @unknown default: break
                                }
                            }
                        HStack {
                            Text(Scrubber.format(position))
                            Spacer()
                            Text(TimeLabel.remaining(remote.duration - position))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14))
        .accessibilityIdentifier("tvRemote.nowPlaying")
    }
}

private struct RemoteButton: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void
    @State private var presses = 0
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 64

    var body: some View {
        Button {
            presses += 1
            action()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.title2.weight(.medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(.platformGlass)
        .buttonBorderShape(.circle)
        .sensoryFeedback(.impact(weight: .light), trigger: presses)
        .accessibilityIdentifier("tvRemote.\(identifier)")
    }
}

/// The library's touch surface, as on Apple TV's remote: a swipe moves focus a step, dragging on
/// moves it again, a flick glides on a few more, and a tap selects, each with a tick under the
/// finger. `TVSwipe` reads the touch. VoiceOver moves with its actions instead.
private struct SwipeSurface: View {
    let onMove: (TVDirection) -> Void
    let onSelect: () -> Void
    /// The touch under way.
    @State private var swipe: TVSwipe?
    @State private var touch: CGPoint?
    @State private var moves = 0
    @State private var selects = 0
    /// The steps a flick glides on by after the finger lifts.
    @State private var glide: Task<Void, Never>?

    var body: some View {
        RemoteSurfaceBackground(hint: "Swipe to move · Tap to select")
            .overlay {
                if let touch {
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.28), .white.opacity(0)], center: .center, startRadius: 0, endRadius: 70))
                        .frame(width: 140, height: 140)
                        .position(touch)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(.rect(cornerRadius: 32))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // A touch stops a glide.
                    if swipe == nil { glide?.cancel() }
                    touch = value.location
                    var current = swipe ?? TVSwipe(from: value.startLocation)
                    if let direction = current.moved(to: value.location, at: value.time) { move(direction) }
                    swipe = current
                }
                .onEnded { value in
                    let ended = swipe ?? TVSwipe(from: value.startLocation)
                    switch ended.ended(translation: value.translation, velocity: value.velocity) {
                    case .tap:
                        selects += 1
                        onSelect()
                    case .swipe(let direction, let owesMove, let steps):
                        if owesMove { move(direction) }
                        glideOn(direction, steps: steps)
                    }
                    swipe = nil
                    withAnimation(.easeOut(duration: 0.25)) { touch = nil }
                })
            .sensoryFeedback(.selection, trigger: moves)
            .sensoryFeedback(.impact(weight: .medium), trigger: selects)
            .accessibilityElement()
            .accessibilityLabel("Touch Surface")
            .accessibilityHint("Selects. Swipe up or down with one finger to move.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: "Up") { onMove(.up) }
            .accessibilityAction(named: "Down") { onMove(.down) }
            .accessibilityAction(named: "Left") { onMove(.left) }
            .accessibilityAction(named: "Right") { onMove(.right) }
            .accessibilityIdentifier("tvRemote.surface")
    }

    private func move(_ direction: TVDirection) {
        moves += 1
        onMove(direction)
    }

    /// Goes on by `steps`, slowing as it goes.
    private func glideOn(_ direction: TVDirection, steps: Int) {
        guard steps > 0 else { return }
        glide = Task {
            for step in 0..<steps {
                try? await Task.sleep(for: .milliseconds(70 + step * 25))
                guard !Task.isCancelled else { return }
                move(direction)
            }
        }
    }
}

/// YouTube's trackpad: one finger moves the pointer, faster the faster it goes, a tap clicks,
/// and two fingers scroll. Full Screen is in its corner, for the video playing.
private struct TrackpadSurface: View {
    @Environment(TVRemote.self) private var remote
    @State private var clicks = 0

    var body: some View {
        RemoteSurfaceBackground(hint: "Drag to point · Tap to click · Two fingers to scroll")
            .overlay {
                TrackpadGestures { dx, dy in
                    remote.movePointer(dx: dx, dy: dy)
                } onClick: {
                    clicks += 1
                    remote.click()
                } onScroll: { dx, dy in
                    remote.press(.scroll(dx: dx, dy: dy))
                }
                .accessibilityElement()
                .accessibilityLabel("Trackpad")
                .accessibilityHint("Clicks where the pointer is.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { remote.click() }
                .accessibilityAction(named: "Scroll Up") { remote.press(.scroll(dx: 0, dy: -400)) }
                .accessibilityAction(named: "Scroll Down") { remote.press(.scroll(dx: 0, dy: 400)) }
                .accessibilityIdentifier("tvRemote.trackpad")
            }
            .overlay(alignment: .topTrailing) {
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { remote.press(.fullScreen) }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .buttonStyle(.platformGlass)
                    .buttonBorderShape(.circle)
                    .padding(12)
                    .accessibilityIdentifier("tvRemote.fullScreen")
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: clicks)
    }
}

/// UIKit's recognizers, which tell one finger from two as SwiftUI's gestures don't.
private struct TrackpadGestures: UIViewRepresentable {
    /// By fractions of the TV's width and height.
    let onMove: (Double, Double) -> Void
    let onClick: () -> Void
    /// By the TV's points, positive moving the content up and left.
    let onScroll: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        let point = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.point(_:)))
        point.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap))
        [point, scroll, tap].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: TrackpadGestures?

        @objc func point(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.width > 0 else { return }
            let moved = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            let velocity = recognizer.velocity(in: view)
            // Slow for aiming, quicker across the screen: the trackpad's width is from a third of
            // the TV's to a little over all of it.
            let gain = 0.3 + min(0.8, hypot(velocity.x, velocity.y) / 2500)
            let width = view.bounds.width
            // The same distance across the TV either way: its height is 9/16 of its width.
            parent?.onMove(moved.x * gain / width, moved.y * gain / width * 16 / 9)
        }

        @objc func scroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let moved = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            // Fingers going up move the page's content up, as on a trackpad, at the TV's size.
            parent?.onScroll(-moved.x * 3, -moved.y * 3)
        }

        @objc func tap() {
            parent?.onClick()
        }
    }
}

private struct RemoteSurfaceBackground: View {
    let hint: String

    var body: some View {
        RoundedRectangle(cornerRadius: 32)
            .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.08)))
            .overlay(alignment: .bottom) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 14)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 220)
    }
}

private extension TVPress {
    init(_ direction: TVDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}
#endif
