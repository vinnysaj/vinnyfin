import SwiftUI

/// What plays somewhere else: the playback on screen, or a title from its page.
enum PlayElsewhereSubject {
    case playback(PlayerModel)
    case title(JellyfinItem, mediaSourceId: String?)

    var item: JellyfinItem? {
        switch self {
        case .playback(let model): model.item
        case .title(let item, _): item
        }
    }

    /// What plays here once a group starts: the title from its page; the playback on screen plays
    /// already.
    var request: PlaybackRequest? {
        guard case .title(let item, let mediaSourceId) = self else { return nil }
        return .item(item, mediaSourceId: mediaSourceId)
    }
}

extension SharePlay {
    /// SharePlay's button shows: on a FaceTime call, to watch with everyone on it, or while
    /// watching together, to leave.
    var isOffered: Bool { isEligible || group != nil }

    /// What SharePlay's button does for `subject`: starts watching it together with everyone on
    /// the call, or, while a group watches, shows it with `showGroup`.
    func buttonTapped(for subject: PlayElsewhereSubject, showGroup: () -> Void) {
        if group != nil { return showGroup() }
        guard let item = subject.item,
              let activity = activity(itemId: item.id, title: item.titleWithYear, subtitle: PlaybackResolver.subtitle(item)) else { return }
        let request = subject.request
        Task { await start(activity, playing: request) }
    }

    static let buttonTitle = "SharePlay"
    static let symbol = "shareplay"
}

/// Watches a title with the people on a FaceTime call, from its page: there only during a call,
/// or while a group watches, which it shows.
struct SharePlayButton: View {
    let subject: PlayElsewhereSubject

    @Environment(SharePlay.self) private var sharePlay
    @State private var showsGroup = false

    var body: some View {
        if sharePlay.isOffered {
            Button {
                sharePlay.buttonTapped(for: subject) { showsGroup = true }
            } label: {
                Label(SharePlay.buttonTitle, systemImage: SharePlay.symbol)
            }
            .titleActionStyle()
            .actionCaption(SharePlay.buttonTitle)
            .help(sharePlay.group == nil ? "Watch Together on This Call" : SharePlay.buttonTitle)
            .accessibilityHint(sharePlay.group == nil ? "Watches with everyone on the call" : "")
            .accessibilityIdentifier("sharePlay")
            .sheet(isPresented: $showsGroup) {
                SharePlaySheet(subject: subject)
            }
        }
    }
}

/// The group watching together: who's watching and who can't, and the ways out of it. Should the
/// group end with the call still on, a new one can start from it.
struct SharePlaySheet: View {
    let subject: PlayElsewhereSubject

    @Environment(SharePlay.self) private var sharePlay
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let group = sharePlay.group {
                        LabeledContent(group.title, value: group.participantCount == 1 ? "1 Watching" : "\(group.participantCount) Watching")
                        ForEach(group.cantWatch, id: \.self) { reason in
                            Label(reason, systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.secondary)
                        }
                        Button("Leave SharePlay", systemImage: "rectangle.portrait.and.arrow.right") {
                            sharePlay.leave()
                            dismiss()
                        }
                        Button("End SharePlay for Everyone", systemImage: "xmark.circle", role: .destructive) {
                            sharePlay.endForEveryone()
                            dismiss()
                        }
                    } else {
                        Button("Watch Together on This Call", systemImage: SharePlay.symbol) {
                            dismiss()
                            sharePlay.buttonTapped(for: subject) {}
                        }
                        .accessibilityIdentifier("sharePlay.start")
                    }
                } footer: {
                    if let serverName {
                        Text("Everyone watches from their own sign-in to \(serverName), in step: pauses, seeks, speed and the next episode are shared.")
                    }
                }
            }
            .screenTitle(SharePlay.buttonTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #elseif os(visionOS)
        // Room for the rows of a group under way, in a sheet fitted to it rather than a tall one
        // over the picture: a list has no height of its own to fit to.
        .frame(width: 540, height: 400)
        .presentationSizing(.fitted)
        #endif
        // The call ended, and the group with it: nothing left here.
        .onChange(of: sharePlay.isOffered) { _, offered in
            if !offered { dismiss() }
        }
    }

    private var serverName: String? {
        if let group = sharePlay.group { return group.serverName }
        guard let item = subject.item else { return nil }
        return sharePlay.activity(itemId: item.id, title: item.titleWithYear)?.serverName
    }
}

#if os(iOS) || os(macOS)
/// Opens `PlayOnSheet` for a title, from its page.
struct PlayOnButton: View {
    let subject: PlayElsewhereSubject

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Label(PlayOnSheet.title, systemImage: PlayOnSheet.symbol)
        }
        .titleActionStyle()
        .actionCaption(PlayOnSheet.title)
        .help(PlayOnSheet.title)
        .accessibilityIdentifier("playOn")
        .sheet(isPresented: $isShowing) {
            PlayOnSheet(subject: subject) {}
        }
    }
}

/// Playing on another device, through the server's remote control. The devices that can play now
/// are listed, vinnyfin on Apple TV first, then vinnyfin elsewhere and other Jellyfin apps;
/// vinnyfin devices seen before stay listed while closed, as ones to open first.
struct PlayOnSheet: View {
    let subject: PlayElsewhereSubject
    /// Called once the playback here went to another device, to close the player.
    let onHandedOver: () -> Void

    @Environment(AccountStore.self) private var accounts
    @Environment(RemoteControl.self) private var remote
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [PlayTarget]?
    @State private var known: [KnownDevice] = []
    @State private var loadError: String?
    @State private var sendingTo: PlayTarget.ID?
    @State private var sendError: String?

    static let title = "Play On"
    static let symbol = "tv.and.mediabox"

    var body: some View {
        NavigationStack {
            List {
                devices
            }
            .overlay {
                if targets == nil, loadError == nil { ProgressView() }
            }
            .screenTitle(Self.title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
        .task { await refreshWhileOpen() }
    }

    @ViewBuilder private var devices: some View {
        Section {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let targets {
                ForEach(targets) { target in targetRow(target) }
                ForEach(KnownDevice.absent(from: targets, in: known)) { device in knownRow(device) }
                if targets.isEmpty, known.isEmpty {
                    // The footer says how one shows up.
                    Text("No devices are open right now.")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Apple TVs and other devices show up here while vinnyfin or another Jellyfin app is open on them, signed in to \(serverName). The server can't open an app that's closed.")
        }
    }

    private var serverName: String {
        accounts.account.map { $0.serverName ?? $0.serverURL.host() ?? "your server" } ?? "your server"
    }

    private func targetRow(_ target: PlayTarget) -> some View {
        Button {
            Task { await send(to: target) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: target.symbol)
                    .font(.title2)
                    .frame(width: 36)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).foregroundStyle(.primary)
                    Text(target.detail(signedInAs: accounts.account?.userName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if sendingTo == target.id { ProgressView() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(sendingTo != nil)
        .accessibilityIdentifier("playOn.target")
    }

    private func knownRow(_ device: KnownDevice) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).foregroundStyle(.secondary)
                Text("vinnyfin isn't open there. Open it to play on \(device.name).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playOn.closed")
    }

    /// The server lists a device once its app opens, so the list keeps up while it's shown.
    private func refreshWhileOpen() async {
        known = remote.knownDevices
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refresh() async {
        guard let client = accounts.client, let account = accounts.account else { return }
        do {
            let sessions = try await client.controllableSessions(userId: account.userId)
            let found = PlayTarget.targets(from: sessions, excludingDeviceId: accounts.deviceId)
            targets = found
            remote.noteTargets(found)
            known = remote.knownDevices
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = "Couldn't ask the server which devices are open: \(error.localizedDescription)"
            if targets == nil { targets = [] }
        }
    }

    private func send(to target: PlayTarget) async {
        sendingTo = target.id
        defer { sendingTo = nil }
        do {
            switch subject {
            case .playback(let model):
                try await remote.handOver(model, to: target)
                dismiss()
                onHandedOver()
            case .title(let item, let mediaSourceId):
                try await remote.send(item, mediaSourceId: mediaSourceId, from: item.resumeSeconds ?? 0, to: target)
                dismiss()
            }
        } catch {
            sendError = "Couldn't play on \(target.name): \(error.localizedDescription)"
        }
    }
}
#endif
