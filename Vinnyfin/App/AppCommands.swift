#if !os(tvOS)
import SwiftUI

/// A command of the Playback menu. Its keys have no modifier, as in other players: there's
/// nothing to type into while one plays.
///
/// iPadOS hands a key without modifiers to the focused view before any menu shortcut, so the
/// menu never sees these keys there: the player, which takes focus as it opens, handles them
/// with `pressed(_:modifiers:)`, and the menu shows them and acts when clicked.
enum PlayerCommand: CaseIterable {
    case playPause, skipBack, skipForward, nextEpisode
    case volumeUp, volumeDown, mute, subtitles
    case fullScreen
    /// Closes an open panel, else leaves full screen, else closes the player.
    case close

    var shortcut: KeyboardShortcut {
        switch self {
        case .playPause: KeyboardShortcut(.space, modifiers: [])
        case .skipBack: KeyboardShortcut(.leftArrow, modifiers: [])
        case .skipForward: KeyboardShortcut(.rightArrow, modifiers: [])
        case .nextEpisode: KeyboardShortcut("n", modifiers: [])
        case .volumeUp: KeyboardShortcut(.upArrow, modifiers: [])
        case .volumeDown: KeyboardShortcut(.downArrow, modifiers: [])
        case .mute: KeyboardShortcut("m", modifiers: [])
        case .subtitles: KeyboardShortcut("c", modifiers: [])
        case .fullScreen: KeyboardShortcut("f", modifiers: [])
        case .close: KeyboardShortcut(.escape, modifiers: [])
        }
    }

    /// Every command's key, for the player to listen for.
    static let keys = Set(allCases.map(\.shortcut.key))

    /// The command a key press stands for, if any.
    static func pressed(_ key: KeyEquivalent, modifiers: EventModifiers) -> PlayerCommand? {
        allCases.first { $0.shortcut.key == key && $0.shortcut.modifiers == modifiers }
    }
}

/// A command of the Go menu: a tab, by its place with ⌘, and Search with ⌘F.
enum TabCommand: CaseIterable {
    case home, movies, shows, downloads, search

    var destination: MainTabs.Destination {
        switch self {
        case .home: .home
        case .movies: .movies
        case .shows: .shows
        case .downloads: .downloads
        case .search: .search
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .shows: "Shows"
        case .downloads: "Downloads"
        case .search: "Search"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .home: KeyboardShortcut("1")
        case .movies: KeyboardShortcut("2")
        case .shows: KeyboardShortcut("3")
        case .downloads: KeyboardShortcut("4")
        case .search: KeyboardShortcut("f")
        }
    }
}

/// The playback the Playback menu acts on, as the player view with keyboard focus hands it over.
struct PlayerCommandTarget {
    let model: PlayerModel
    /// The picture fills the screen, cutting its edges, on iPhone and iPad.
    let fillsScreen: Bool
    /// The Mac's player window is in full screen.
    let isFullScreen: Bool
    let perform: (PlayerCommand) -> Void
}

/// The tabs the Go menu moves between, as the focused window's tabs hand them over.
struct TabCommandTarget {
    let go: (TabCommand) -> Void
    /// Back a page in the tab showing; nil on a tab's first page.
    var back: (() -> Void)?

    /// ⌘[, as in Finder and Safari.
    static let backShortcut = KeyboardShortcut("[", modifiers: .command)
}

extension FocusedValues {
    @Entry var player: PlayerCommandTarget?
    @Entry var tabs: TabCommandTarget?
}

/// The Playback and Go menus: in the Mac's menu bar and iPad's, which list their keys, and as
/// keys alone with a keyboard on iPhone and Vision Pro.
struct AppCommands: Commands {
    @FocusedValue(\.player) private var player
    @FocusedValue(\.tabs) private var tabs

    var body: some Commands {
        CommandMenu("Playback") {
            button(player?.model.isPlaying == true ? "Pause" : "Play", .playPause)
            button("Back \(Int(PlayerModel.skipInterval)) Seconds", .skipBack)
            button("Forward \(Int(PlayerModel.skipInterval)) Seconds", .skipForward)
            button("Next Episode", .nextEpisode, enabled: player?.model.nextEpisode != nil)
            Divider()
            button("Volume Up", .volumeUp)
            button("Volume Down", .volumeDown)
            button(player?.model.volume.isMuted == true ? "Unmute" : "Mute", .mute)
            Divider()
            audioPicker
            subtitlePicker
            button(player?.model.selectedSubtitle != nil ? "Turn Subtitles Off" : "Turn Subtitles On", .subtitles,
                   enabled: player?.model.subtitleOptions.isEmpty == false)
            Divider()
            #if os(macOS)
            button(player?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen", .fullScreen)
            // Escape leaves full screen before it closes the player.
            button(player?.isFullScreen == true ? "Exit Full Screen" : "Close Player", .close)
            #elseif os(iOS)
            button(player?.fillsScreen == true ? "Fit to Screen" : "Fill Screen", .fullScreen)
            button("Close Player", .close)
            #else
            button("Close Player", .close)
            #endif
        }
        CommandMenu("Go") {
            Button("Back") { tabs?.back?() }
                .keyboardShortcut(TabCommandTarget.backShortcut)
                .disabled(tabs?.back == nil)
            Divider()
            ForEach(TabCommand.allCases, id: \.self) { command in
                Button(command.title) { tabs?.go(command) }
                    .keyboardShortcut(command.shortcut)
                    .disabled(tabs == nil)
            }
        }
    }

    private func button(_ title: String, _ command: PlayerCommand, enabled: Bool = true) -> some View {
        Button(title) { player?.perform(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(player == nil || !enabled)
    }

    private var audioPicker: some View {
        Picker("Audio", selection: Binding(get: { player?.model.selectedAudio }, set: { id in
            if let id { player?.model.chooseAudio(id) }
        })) {
            ForEach(player?.model.audioOptions ?? []) { option in
                Text(option.title).tag(Optional(option.id))
            }
        }
        .disabled(player?.model.audioOptions.isEmpty ?? true)
    }

    private var subtitlePicker: some View {
        Picker("Subtitles", selection: Binding(get: { player?.model.selectedSubtitle }, set: { id in
            player?.model.chooseSubtitle(id)
        })) {
            Text("Off").tag(Int?.none)
            ForEach(player?.model.subtitleOptions ?? []) { option in
                Text(option.title).tag(Optional(option.id))
            }
        }
        .disabled(player == nil)
    }
}
#endif

#if os(macOS)
/// Portable TV in the View menu: on and off, and the library or YouTube while it's on, as the
/// remote's switch has them.
struct PortableTVCommands: Commands {
    let tv: PortableTV
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(tv.isOn ? "Turn Off Portable TV" : "Turn On Portable TV") {
                if tv.isOn { dismissWindow(id: PortableTVWindow.id) } else { openWindow(id: PortableTVWindow.id) }
            }
            .keyboardShortcut("t", modifiers: [.control, .command])
            Button("Show Library") { tv.press(.home(.library)) }
                .keyboardShortcut("1", modifiers: [.option, .command])
                .disabled(!tv.isOn)
            Button("Show YouTube") { tv.press(.home(.youTube)) }
                .keyboardShortcut("2", modifiers: [.option, .command])
                .disabled(!tv.isOn)
            Divider()
        }
    }
}
#endif
