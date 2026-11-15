#if !os(tvOS)
import SwiftUI

/// A command of the Playback menu. Most keys have no modifier, as in other players: there's
/// nothing to type into while one plays.
///
/// iPadOS hands a key without modifiers to the focused view before any menu shortcut, so the
/// menu never sees these keys there: the player, which takes focus as it opens, handles them
/// with `pressed(_:modifiers:)`, and the menu shows them and acts when clicked. The player
/// handles a key the menu doesn't list the same way, as Escape on the Mac.
enum PlayerCommand: CaseIterable {
    case playPause, skipBack, skipForward, previousEpisode, nextEpisode, episodes
    case previousChapter, nextChapter
    case volumeUp, volumeDown, mute, subtitles
    case fullScreen
    /// Closes an open panel, else leaves full screen, else closes the player.
    case close
    /// Picture in Picture on and off, and the window kept above others: the Mac's, with no key.
    case pictureInPicture, floatOnTop

    var shortcut: KeyboardShortcut? {
        switch self {
        case .playPause: KeyboardShortcut(.space, modifiers: [])
        case .skipBack: KeyboardShortcut(.leftArrow, modifiers: [])
        case .skipForward: KeyboardShortcut(.rightArrow, modifiers: [])
        case .previousEpisode: KeyboardShortcut("p", modifiers: [])
        case .nextEpisode: KeyboardShortcut("n", modifiers: [])
        case .episodes: KeyboardShortcut("e", modifiers: [])
        // As QuickTime Player's.
        case .previousChapter: KeyboardShortcut(.leftArrow, modifiers: [.shift, .command])
        case .nextChapter: KeyboardShortcut(.rightArrow, modifiers: [.shift, .command])
        case .volumeUp: KeyboardShortcut(.upArrow, modifiers: [])
        case .volumeDown: KeyboardShortcut(.downArrow, modifiers: [])
        case .mute: KeyboardShortcut("m", modifiers: [])
        case .subtitles: KeyboardShortcut("c", modifiers: [])
        case .fullScreen: KeyboardShortcut("f", modifiers: [])
        case .close: KeyboardShortcut(.escape, modifiers: [])
        case .pictureInPicture, .floatOnTop: nil
        }
    }

    /// Every command's key, for the player to listen for.
    static let keys = Set(allCases.compactMap(\.shortcut?.key))

    /// The command a key press stands for, if any.
    static func pressed(_ key: KeyEquivalent, modifiers: EventModifiers) -> PlayerCommand? {
        allCases.first { $0.shortcut?.key == key && $0.shortcut?.modifiers == modifiers }
    }

    /// Whether the command has anything to act on in the playback `offers`.
    func isEnabled(in offers: PlayerCommandOffers) -> Bool {
        switch self {
        case .previousEpisode, .episodes: offers.isEpisode
        case .nextEpisode: offers.hasNextEpisode
        case .previousChapter, .nextChapter: offers.hasChapters
        case .subtitles: offers.hasSubtitles
        case .pictureInPicture: offers.pictureInPicture.map { $0.isPossible || $0.isActive } ?? false
        case .playPause, .skipBack, .skipForward, .volumeUp, .volumeDown, .mute, .fullScreen, .close, .floatOnTop: true
        }
    }

    /// A control's tooltip: its name and the key that does the same, "Play (Space)".
    func tooltip(_ name: String) -> String {
        guard let keys = keyName else { return name }
        return "\(name) (\(keys))"
    }

    /// The command's key as a menu writes it: "Space", "←", "⇧⌘→", "N".
    var keyName: String? {
        guard let shortcut else { return nil }
        var name = ""
        if shortcut.modifiers.contains(.control) { name += "⌃" }
        if shortcut.modifiers.contains(.option) { name += "⌥" }
        if shortcut.modifiers.contains(.shift) { name += "⇧" }
        if shortcut.modifiers.contains(.command) { name += "⌘" }
        switch shortcut.key {
        case .space: name += "Space"
        case .leftArrow: name += "←"
        case .rightArrow: name += "→"
        case .upArrow: name += "↑"
        case .downArrow: name += "↓"
        case .escape: name += "Esc"
        default: name += String(shortcut.key.character).uppercased()
        }
        return name
    }
}

/// What a playback offers the commands that depend on it (`PlayerCommand.isEnabled(in:)`).
struct PlayerCommandOffers {
    var isEpisode = false
    var hasNextEpisode = false
    var hasChapters = false
    var hasSubtitles = false
    /// Nil where there's no Picture in Picture.
    var pictureInPicture: PictureInPictureButton?
}

extension ChapterMark {
    /// Where Next Chapter goes from `seconds`: the next chapter's start, none in the last.
    static func next(in chapters: [ChapterMark], after seconds: Double) -> ChapterMark? {
        chapters.first { $0.start > seconds + 0.5 }
    }

    /// Where Previous Chapter goes from `seconds`: back to the start of the chapter playing, or,
    /// within its first few seconds, as a CD player's does, to the start of the one before. None
    /// before the first chapter starts.
    static func previous(in chapters: [ChapterMark], before seconds: Double) -> ChapterMark? {
        guard let current = current(in: chapters, at: seconds) else { return nil }
        guard seconds - current.start < restartWindow else { return current }
        return chapters.last { $0.start < current.start } ?? current
    }

    /// How far into a chapter Previous Chapter goes back to its start rather than to the one before.
    static let restartWindow: Double = 3
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
    /// The Mac's player window floats above other windows.
    var floatsOnTop = false
    /// Picture in Picture's state; nil where there's none.
    var pictureInPicture: PictureInPictureButton?
    let perform: (PlayerCommand) -> Void

    /// What the playback offers the commands that depend on it.
    var offers: PlayerCommandOffers {
        PlayerCommandOffers(isEpisode: model.item?.isEpisode == true, hasNextEpisode: model.nextEpisode != nil,
                            hasChapters: !model.chapters.isEmpty, hasSubtitles: !model.subtitleOptions.isEmpty,
                            pictureInPicture: pictureInPicture)
    }
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
            Divider()
            button("Previous Episode", .previousEpisode)
            button("Next Episode", .nextEpisode)
            button("Episodes", .episodes)
            button("Previous Chapter", .previousChapter)
            button("Next Chapter", .nextChapter)
            Divider()
            speedPicker
            button("Volume Up", .volumeUp)
            button("Volume Down", .volumeDown)
            button(player?.model.volume.isMuted == true ? "Unmute" : "Mute", .mute)
            Divider()
            audioPicker
            subtitlePicker
            button(player?.model.selectedSubtitle != nil ? "Turn Subtitles Off" : "Turn Subtitles On", .subtitles)
            Divider()
            #if os(macOS)
            button(player?.pictureInPicture?.isActive == true ? "Exit Picture in Picture" : "Enter Picture in Picture",
                   .pictureInPicture)
            Toggle("Float on Top", isOn: Binding(get: { player?.floatsOnTop ?? false }, set: { _ in player?.perform(.floatOnTop) }))
                .disabled(player == nil)
            button(player?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen", .fullScreen)
            // Escape isn't listed: in full screen it would be a second Exit Full Screen. The player
            // takes it as it takes the keys (`PlayerCommand`), and File › Close closes the player.
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

    private func button(_ title: String, _ command: PlayerCommand) -> some View {
        Button(title) { player?.perform(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(player.map { !command.isEnabled(in: $0.offers) } ?? true)
    }

    private var speedPicker: some View {
        Picker("Speed", selection: Binding(get: { player?.model.rate ?? 1 }, set: { player?.model.setRate($0) })) {
            ForEach(PlaybackSpeed.choices, id: \.self) { rate in
                Text(PlaybackSpeed.name(rate)).tag(rate)
            }
        }
        .disabled(player == nil)
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
