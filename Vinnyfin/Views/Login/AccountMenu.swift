import SwiftUI

#if !os(tvOS)
/// The avatar on Home: who's signed in to which server, the other sign-ins kept on this device to
/// switch to, a way to add one, and Settings.
struct AccountMenu: View {
    /// Opens Settings; nil on the Mac, where Settings is a window of its own.
    var openSettings: (() -> Void)?

    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @State private var addingAccount = false

    var body: some View {
        Menu {
            if let account = accounts.account {
                Section("Signed In") {
                    Text("\(account.userName) on \(account.serverTitle)")
                }
            }
            if !accounts.others.isEmpty {
                Section("Switch To") {
                    ForEach(accounts.others, id: \.tokenKey) { account in
                        Button {
                            switchTo(account)
                        } label: {
                            Text(account.userName)
                            Text(account.serverTitle)
                        }
                        .accessibilityIdentifier("home.switchAccount")
                    }
                }
            }
            Section {
                Button("Add Account", systemImage: "person.crop.circle.badge.plus") { addingAccount = true }
                    .accessibilityIdentifier("home.addAccount")
                if let openSettings {
                    Button("Settings", systemImage: "gear", action: openSettings)
                        .accessibilityIdentifier("home.openSettings")
                } else {
                    #if os(macOS)
                    SettingsLink {
                        Label("Settings…", systemImage: "gear")
                    }
                    .accessibilityIdentifier("home.openSettings")
                    #endif
                }
            }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
        .accessibilityIdentifier("home.settings")
        .sheet(isPresented: $addingAccount) { LoginView(addsAccount: true) }
    }

    private func switchTo(_ account: AccountStore.Account) {
        Task { await switchAccount(to: account, accounts: accounts, player: player, messages: messages) }
    }
}

extension AccountStore {
    /// Signs out of `account`, the one in use when nil, cancelling its downloads that haven't
    /// finished: only its sign-in can fetch them. The server's copies of their transcodes are
    /// deleted before it's told, while the sign-in still works there.
    func signOut(of account: Account? = nil, cancelling downloads: DownloadManager) {
        guard let account = account ?? self.account else {
            signOut()
            return
        }
        downloads.removeUnfinished(of: account)
        let transcodes = downloads.transcodes
        signOut(of: account) { await transcodes.finishCleanups() }
    }
}
#else
/// On Apple TV, whose Home has no avatar, Settings' rows for the other sign-ins kept here to
/// switch to, and for adding one.
struct AccountRows: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @State private var addingAccount = false

    var body: some View {
        ForEach(accounts.others, id: \.tokenKey) { account in
            Button {
                Task { await switchAccount(to: account, accounts: accounts, player: player, messages: messages) }
            } label: {
                LabeledContent("Switch to \(account.userName)", value: account.serverTitle)
            }
            .accessibilityIdentifier("settings.switchAccount")
        }
        Button("Add Account") { addingAccount = true }
            .accessibilityIdentifier("settings.addAccount")
            .sheet(isPresented: $addingAccount) { LoginView(addsAccount: true) }
    }
}
#endif

/// Switches the app to another sign-in kept on this device, once what plays has stopped and told
/// the server of the sign-in in use where it got to.
@MainActor
func switchAccount(to account: AccountStore.Account, accounts: AccountStore, player: PlayerCoordinator, messages: AppMessages) async {
    await player.dismiss()
    do {
        try accounts.switchTo(account)
    } catch {
        messages.show(error.localizedDescription)
    }
}
