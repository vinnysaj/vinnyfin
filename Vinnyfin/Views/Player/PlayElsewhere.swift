import SwiftUI

/// What a SharePlay group watches: the playback on screen, or a title from its page.
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
