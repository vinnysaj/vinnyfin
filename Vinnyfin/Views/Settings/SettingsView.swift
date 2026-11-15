import Combine
import SwiftUI

/// Settings: the account the app is signed in with, then a page for each kind of setting. On the
/// Mac, a pane for each in the Settings window.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    /// Opened as a sheet, which Done closes, rather than as a tab.
    @Environment(\.isPresented) private var isPresented

    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                SettingsForm("General") {
                    AccountSection()
                    AppearanceSection()
                }
            }
            ForEach(SettingsPage.allCases) { page in
                Tab(page.paneTitle, systemImage: page.systemImage) { page.content }
            }
        }
        .frame(width: 600)
        .frame(minHeight: 460, idealHeight: 560)
        // The Mac's Settings window is a window of its own, outside the root view.
        .preferredColorScheme(settings.appearance.colorScheme)
        #else
        NavigationStack {
            SettingsForm("Settings", isFirstPage: true) {
                if let account = accounts.account {
                    Section {
                        NavigationLink {
                            SettingsForm("Account") { AccountSection() }
                        } label: {
                            AccountSummary(account: account)
                        }
                        .accessibilityIdentifier("settings.account")
                    }
                }
                #if !os(visionOS)
                AppearanceSection()
                #endif
                Section {
                    ForEach(SettingsPage.allCases) { page in
                        NavigationLink {
                            page.content
                        } label: {
                            Label(page.title, systemImage: page.systemImage)
                        }
                        .accessibilityIdentifier("settings.\(page.rawValue)")
                    }
                }
            }
            #if os(iOS) || os(visionOS)
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            #endif
        }
        #endif
    }

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// The kinds of setting, each a page of its own, or on the Mac a pane.
private enum SettingsPage: String, CaseIterable, Identifiable {
    case playback
    case audioAndSubtitles
    #if !os(tvOS)
    case downloads
    case notificationsAndSpotlight
    #endif
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .playback: "Playback"
        case .audioAndSubtitles: "Audio and Subtitles"
        #if !os(tvOS)
        case .downloads: "Downloads and Storage"
        case .notificationsAndSpotlight: "Notifications and Spotlight"
        #endif
        case .about: "About"
        }
    }

    /// The name on its pane's button in the Mac's Settings window, which has room for a word or two.
    var paneTitle: String {
        switch self {
        #if !os(tvOS)
        case .downloads: "Downloads"
        case .notificationsAndSpotlight: "Notifications"
        #endif
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .playback: "play.rectangle"
        case .audioAndSubtitles: "captions.bubble"
        #if !os(tvOS)
        case .downloads: "arrow.down.circle"
        case .notificationsAndSpotlight: "bell"
        #endif
        case .about: "info.circle"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .playback: SettingsForm(title) { PlaybackSettings() }
        case .audioAndSubtitles: SettingsForm(title) { AudioAndSubtitleSettings() }
        #if !os(tvOS)
        case .downloads: SettingsForm(title) { DownloadSettings() }
        case .notificationsAndSpotlight: SettingsForm(title) { NotificationAndSpotlightSettings() }
        #endif
        case .about: SettingsForm(title) { AboutSettings() }
        }
    }
}

/// A page of settings. Apple TV heads it with its title, as its bar shows none; there the sidebar
/// names the first page.
private struct SettingsForm<Content: View>: View {
    let title: String
    var isFirstPage = false
    @ViewBuilder let content: Content

    init(_ title: String, isFirstPage: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isFirstPage = isFirstPage
        self.content = content()
    }

    var body: some View {
        Form {
            #if os(tvOS)
            if !isFirstPage {
                Section {} header: {
                    Text(title).font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
                }
            }
            #endif
            content
        }
        .formStyle(.grouped)
        .screenTitle(title)
        #if os(tvOS)
        .toggleStyle(SettingToggleStyle())
        // Rows fade out as they scroll up under the sidebar's tab in the top corner, which shows
        // over the first page only.
        .mask {
            VStack(spacing: 0) {
                Color.clear.frame(height: isFirstPage ? Self.tabBottom : 0)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: isFirstPage ? Self.fadeHeight : 0)
                Color.black
            }
            .ignoresSafeArea()
        }
        #endif
    }

    #if os(tvOS)
    /// How far down the screen the sidebar's tab, collapsed in the top corner, reaches.
    private static var tabBottom: CGFloat { 100 }
    /// Below the tab, where rows fade in, ending above the first section's header.
    private static var fadeHeight: CGFloat { 28 }
    #endif
}

// MARK: Account

/// Who the app is signed in as, and where: the first row of Settings, which leads to the account.
private struct AccountSummary: View {
    let account: AccountStore.Account

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.userName).font(.headline)
                Text(account.serverName ?? account.serverURL.host() ?? "Jellyfin")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The server, the account and this device's remote control, and signing out, last: on Apple
/// TV, where these rows take no focus, first would put focus on it.
private struct AccountSection: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(SessionSocket.self) private var socket
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    @State private var confirmingSignOut = false

    var body: some View {
        if let account = accounts.account {
            Section {
                LabeledContent("Server", value: account.serverName ?? account.serverURL.host() ?? "Jellyfin")
                LabeledContent("Address", value: account.serverURL.absoluteString)
                LabeledContent("Signed In As", value: account.userName)
                #if os(tvOS)
                AccountRows()
                #endif
                LabeledContent("Remote Control", value: socket.state.label)
                    .accessibilityIdentifier("settings.remoteControl")
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    #if os(tvOS)
                    DestructiveTitle("Sign Out")
                    #else
                    Text("Sign Out")
                    #endif
                }
                .accessibilityIdentifier("settings.signOut")
                .confirmationDialog("Sign out of \(account.serverName ?? "the server")?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                    Button("Sign Out", role: .destructive) {
                        #if os(tvOS)
                        accounts.signOut()
                        #else
                        accounts.signOut(cancelling: downloads)
                        #endif
                    }
                } message: {
                    #if os(tvOS)
                    Text("You can sign in again at any time.")
                    #else
                    Text("Unfinished downloads are cancelled. Finished downloads stay and still play.")
                    #endif
                }
            } header: {
                Text("Server")
            } footer: {
                Text("While vinnyfin is open, other Jellyfin apps can play to this \(Device.name), as \(Device.ownName), and control what plays.")
            }
        }
    }
}

private struct AppearanceSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            SettingPicker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.appearance")
        }
    }
}

// MARK: Playback

private struct PlaybackSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            SettingPicker("Streaming Quality", selection: $settings.streamingQuality) {
                ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.streamingQuality")
            #if !os(tvOS)
            SettingPicker(Self.cellularLabel, selection: $settings.cellularStreamingQuality) {
                ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.cellularStreamingQuality")
            #endif
        } footer: {
            Text(qualityNote)
        }
        Section {
            learnedLimit
            Toggle("Transcode When No Version Fits", isOn: $settings.allowTranscoding)
            Toggle("Adaptive Quality", isOn: $settings.adaptiveQuality)
                .accessibilityIdentifier("settings.adaptiveQuality")
        } footer: {
            Text("With Adaptive Quality, a smaller version plays when the connection can't keep up.")
        }
        Section {
            Toggle("Play the Next Episode Automatically", isOn: $settings.autoplayNextEpisode)
            Toggle("Offer to Skip Intros and Credits", isOn: $settings.showSkipButtons)
            SettingPicker("Skip Intros", selection: $settings.introSkipping) {
                ForEach(AppSettings.IntroSkipping.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.introSkipping")
            #if os(tvOS)
            Toggle("Match Frame Rate and Dynamic Range", isOn: $settings.matchContent)
            #endif
        }
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            Section {
                Toggle("Play Videos in Landscape", isOn: $settings.playsVideosInLandscape)
                    .accessibilityIdentifier("settings.playsVideosInLandscape")
            } footer: {
                Text("A widescreen title turns the player sideways, even with Portrait Orientation Lock on. The player's Rotation Lock turns it back upright.")
            }
        }
        #endif
    }

    /// The bitrate Adaptive Quality learned this device's connection carries, while it holds
    /// streams to it.
    @ViewBuilder private var learnedLimit: some View {
        if settings.adaptiveQuality, let limit = settings.learnedQuality.limit {
            LabeledContent {
                Button("Reset") { settings.learnedQuality.reset() }
                    .accessibilityIdentifier("settings.resetLearnedQuality")
            } label: {
                Text("Limited to \(QualityLearning.label(forBitrate: limit)) after buffering on this \(Device.name)")
            }
            .accessibilityIdentifier("settings.learnedQuality")
        }
    }

    #if os(tvOS)
    /// On an Apple TV whose output makes use of no more than 1080p, that it streams no more.
    private var qualityNote: String {
        let display = DisplayOutput.streamingHeight == nil ? "" : " (1080p at most, as this Apple TV outputs 1080p)"
        return "Plays the best version up to this quality\(display) as it is."
    }
    #else
    /// What streams go up to, and on networks that save data, about what an hour of them takes.
    private var qualityNote: String {
        let saving = settings.streamingQuality(on: .lowData)
        guard saving != .original else {
            return "Plays the best version up to this quality as it is, \(Self.savingNetworks) too, where the best can take tens of gigabytes an hour."
        }
        return "Plays the best version up to this quality as it is; \(Self.savingNetworks), up to \(saving.label), about \(Self.hourOfStreaming(at: saving)) an hour."
    }

    /// Roughly what an hour streamed at `quality` takes: what the server's transcodes to it are
    /// asked for. A version played as it is can take more or less.
    static func hourOfStreaming(at quality: VideoQuality) -> String {
        (Int64(quality.transcodeBitrate) * 3600 / 8).formatted(.byteCount(style: .file))
    }

    #if os(iOS)
    private static let cellularLabel: LocalizedStringKey = "Streaming on Cellular"
    private static let savingNetworks = "on cellular data and in Low Data Mode"
    #else
    private static let cellularLabel: LocalizedStringKey = "Streaming on Personal Hotspot"
    private static let savingNetworks = "on a Personal Hotspot and in Low Data Mode"
    #endif
    #endif
}

// MARK: Audio and subtitles

private struct AudioAndSubtitleSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            SettingPicker("Audio Language", selection: $settings.audioLanguage) {
                Text("The Video's Default").tag("")
                ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
            }
        }
        Section {
            SettingPicker("Show Subtitles", selection: $settings.subtitleMode) {
                ForEach(AppSettings.SubtitleMode.allCases) { Text($0.label).tag($0) }
            }
            SettingPicker("Subtitle Language", selection: $settings.subtitleLanguage) {
                ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
            }
            SettingPicker("Subtitle Size", selection: $settings.subtitleScale) {
                Text("Small").tag(0.8)
                Text("Standard").tag(1.0)
                Text("Large").tag(1.25)
                Text("Extra Large").tag(1.5)
            }
        } footer: {
            AccessibleMediaNote()
        }
    }
}

#if !os(tvOS)
// MARK: Downloads and storage

private struct DownloadSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            SettingPicker("Download Quality", selection: $settings.downloadQuality) {
                ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.downloadQuality")
            Toggle("Transcode Downloads When No Version Fits", isOn: $settings.transcodeDownloads)
                .accessibilityIdentifier("settings.transcodeDownloads")
            Toggle("Delete Watched Episodes", isOn: $settings.deleteWatchedEpisodes)
                .accessibilityIdentifier("settings.deleteWatched")
        } header: {
            Text("Downloads")
        } footer: {
            Text("Downloads take the best version up to this quality, or when every version is bigger, the smallest, unless the server is to make one at it, which takes longer.")
        }
        Section {
            Toggle(Self.cellularLabel, isOn: $settings.downloadOverCellular)
                .accessibilityIdentifier("settings.downloadOverCellular")
            Toggle("Only While Charging", isOn: $settings.downloadOnlyWhileCharging)
                .accessibilityIdentifier("settings.onlyWhileCharging")
        } header: {
            Text("When to Download")
        } footer: {
            Text("Downloads also wait while Low Data Mode is on, and Download Now on a waiting one starts it anyway.")
        }
        Section {
            SettingPicker("Storage Limit", selection: $settings.downloadStorageLimit) {
                ForEach(AppSettings.storageLimitChoices, id: \.self) { gigabytes in
                    Text(gigabytes == 0 ? "No Limit" : DownloadManager.bytes(Int64(gigabytes) * 1_000_000_000)).tag(gigabytes)
                }
            }
            .accessibilityIdentifier("settings.storageLimit")
            StorageUsage()
        } header: {
            Text("Storage")
        } footer: {
            Text("To make room, the downloads you watched longest ago since downloading them go first, and unwatched or partly watched ones never do.")
        }
    }

    #if os(iOS)
    private static let cellularLabel: LocalizedStringKey = "Download Over Cellular"
    #else
    private static let cellularLabel: LocalizedStringKey = "Download Over Personal Hotspot"
    #endif
}

// MARK: Notifications and Spotlight

private struct NotificationAndSpotlightSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var accounts
    @Environment(DownloadNotifications.self) private var downloadNotifications
    @Environment(SpotlightTitles.self) private var spotlight
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Download Notifications", isOn: $settings.downloadNotifications)
                .accessibilityIdentifier("settings.downloadNotifications")
                .onChange(of: settings.downloadNotifications) { _, isOn in
                    if isOn { downloadNotifications.requestAuthorizationIfNeeded() }
                }
            if settings.downloadNotifications, downloadNotifications.isDenied {
                #if os(macOS)
                Text("Notifications are off for vinnyfin in System Settings › Notifications.")
                    .foregroundStyle(.secondary)
                #else
                Button("Turn On Notifications in Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                #endif
            }
        } footer: {
            Text("Tells you when downloads are ready to watch offline, and when one fails or waits for room or for your server.")
        }
        .task { await downloadNotifications.refreshAuthorization() }
        spotlightSection
    }

    /// What Spotlight holds of the server's titles, and why it couldn't be updated.
    @ViewBuilder private var spotlightSection: some View {
        if accounts.account != nil || spotlight.problem != nil {
            Section {
                if spotlight.isUpdating {
                    LabeledContent("Spotlight") { ProgressView() }
                } else if let status = spotlight.status, let account = accounts.account,
                          status.serverId == account.serverId, status.userId == account.userId {
                    LabeledContent("In Spotlight", value: status.summary)
                    LabeledContent("Updated", value: status.refreshedAt.formatted(.relative(presentation: .named)))
                }
                if let problem = spotlight.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    if accounts.account != nil {
                        Button("Try Again") { Task { await spotlight.refreshNow() } }
                    }
                }
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Search on the Home Screen finds up to \(SpotlightPlan.limit.formatted()) of your server's movies, shows and episodes, and opens them here.")
            }
        }
    }
}
#endif

// MARK: About

private struct AboutSettings: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: SettingsView.version)
            NavigationLink("Acknowledgements") { AcknowledgementsView() }
            #if os(iOS) || os(visionOS)
            NavigationLink("Diagnostics") { DiagnosticsView() }
                .accessibilityIdentifier("settings.diagnostics")
            #endif
        }
        Section {
            Text("vinnyfin only talks to your Jellyfin server, and to your iCloud, which keeps your servers and most of these settings the same on all your devices. No analytics, no tracking, no accounts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("vinnyfin isn't made by or affiliated with the Jellyfin project. Jellyfin is a trademark of its owners; Dolby, Dolby Atmos, Dolby Vision and DTS are trademarks of their owners.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.notAffiliated")
        }
    }
}

#if os(tvOS)
/// The system's toggle with its name in the text's color, which turns dark on the white of a
/// focused row. Left to itself it draws the name of one that's on in the tint, pale on that white.
/// `.primary` won't do: a form draws that in the tint too.
private struct SettingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label.foregroundStyle(Color.primary)
        }
        .toggleStyle(.automatic)
    }
}

/// A destructive action's title: red, and dark red on the white of a focused row, where the
/// system's red turns pale pink.
private struct DestructiveTitle: View {
    let title: LocalizedStringKey
    @Environment(\.isFocused) private var isFocused

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title).foregroundStyle(isFocused ? Color(red: 0.7, green: 0.04, blue: 0.04) : .red)
    }
}
#endif

/// A setting chosen from a list. On Apple TV it's the setting's name and a button with the
/// choice made, which opens a menu of them: a form's picker there lists every choice inline,
/// with a language list running on for screens.
struct SettingPicker<Value: Hashable, Choices: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder let choices: Choices

    init(_ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder choices: () -> Choices) {
        self.title = title
        _selection = selection
        self.choices = choices()
    }

    var body: some View {
        #if os(tvOS)
        LabeledContent(title) {
            Picker(title, selection: $selection) { choices }
                .pickerStyle(.menu)
                .labelsHidden()
        }
        #else
        Picker(title, selection: $selection) { choices }
        #endif
    }
}

/// The open-source software the app is built on, with the notices their licenses ask for.
struct AcknowledgementsView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let summary: String
        let file: String
        var id: String { name }
    }

    /// Static, not stored: Settings builds this page anew each time it renders, and a stored list
    /// SwiftUI can't compare makes each one look changed, which on Apple TV re-renders the two
    /// screens in turn without end once the page is open.
    private static let components = [
        Component(name: "AetherEngine", license: "LGPL-3.0 with App Store exception",
                  summary: "Copyright (C) 2026 Vincent Herbst. The playback engine. Source: github.com/superuser404notfound/AetherEngine",
                  file: "AetherEngine"),
        Component(name: "FFmpeg", license: "LGPL-2.1 or later",
                  summary: "Reads and decodes media, dynamically linked as built by FFmpegBuild, whose build script publishes the configuration and patches. Source: github.com/superuser404notfound/FFmpegBuild and ffmpeg.org",
                  file: "FFmpeg"),
        Component(name: "dav1d", license: "BSD-2-Clause", summary: "Copyright (c) VideoLAN and dav1d authors. Decodes AV1.", file: "dav1d"),
        Component(name: "zimg", license: "WTFPL", summary: "Scales and converts pictures.", file: "zimg"),
        Component(name: "libzvbi", license: "LGPL-2.1, MIT", summary: "Reads teletext and closed captions.", file: "libzvbi"),
        Component(name: "dovi_tool (libdovi)", license: "MIT",
                  summary: "Copyright (c) quietvoid and contributors. Reads Dolby Vision metadata.", file: "libdovi"),
        Component(name: "SMBClient", license: "MIT", summary: "Copyright (c) 2024 Kishikawa Katsumi.", file: "SMBClient"),
        Component(name: "Nuke", license: "MIT", summary: "Copyright (c) 2015-2026 Alexander Grebenyuk. Loads and caches artwork.", file: "Nuke"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.components) { component in
                    NavigationLink {
                        LicenseView(name: component.name, file: component.file)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(component.name).font(.headline)
                            Text(component.license).font(.subheadline).foregroundStyle(.secondary)
                            Text(component.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                #if os(tvOS)
                Text("Acknowledgements").font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
                #endif
            }
        }
        .screenTitle("Acknowledgements")
    }
}

/// A component's license. On Apple TV focus moves through it a paragraph at a time: a page with
/// nothing to focus can't be scrolled with the remote, and Menu there leaves the app instead of
/// going back.
private struct LicenseView: View {
    let name: String
    /// The license's text file in the app's resources.
    let file: String

    var body: some View {
        let text = Self.text(named: file)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if os(tvOS)
                Text(name).font(.title2.bold())
                ForEach(Array(Self.paragraphs(of: text).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(.caption.monospaced()).focusable()
                }
                #else
                Text(text).font(.caption.monospaced()).textSelection(.enabled)
                #endif
            }
            .padding()
        }
        .screenTitle(name)
    }

    static func text(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The license text is missing from this build." }
        return text
    }

    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// What the system's Accessibility settings change about the audio and subtitle choices, while
/// they change something: nothing shows otherwise.
private struct AccessibleMediaNote: View {
    @State private var captions = AccessibleMedia.prefersCaptions
    @State private var captionStyle = AccessibleMedia.hasCaptionStyle
    @State private var descriptions = AccessibleMedia.prefersAudioDescriptions

    var body: some View {
        let notes = [
            captions ? "Closed Captions + SDH is on in Accessibility settings, so subtitles always show, closed captions first, in the subtitle language or else the audio's." : nil,
            captionStyle ? "Subtitles take the caption style chosen in Accessibility settings, at the size chosen here." : nil,
            descriptions ? "Audio Descriptions is on in Accessibility settings, so a title plays its audio description when it has one." : nil,
        ].compactMap(\.self)
        Group {
            if !notes.isEmpty { Text(notes.joined(separator: " ")) }
        }
        .onReceive(Self.changes) { _ in
            captions = AccessibleMedia.prefersCaptions
            captionStyle = AccessibleMedia.hasCaptionStyle
            descriptions = AccessibleMedia.prefersAudioDescriptions
        }
    }

    /// Either setting changing. On the Mac, System Settings changes them from its own process.
    private static var changes: AnyPublisher<Notification, Never> {
        let names = [AccessibleMedia.captionsChanged, AccessibleMedia.audioDescriptionsChanged]
        #if os(macOS)
        let centers = [NotificationCenter.default, DistributedNotificationCenter.default()]
        #else
        let centers = [NotificationCenter.default]
        #endif
        return Publishers.MergeMany(centers.flatMap { center in names.map { center.publisher(for: $0) } }).eraseToAnyPublisher()
    }
}
