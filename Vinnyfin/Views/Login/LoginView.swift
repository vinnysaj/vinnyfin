import SwiftUI

/// Signs in to a Jellyfin server. Someone new finds their server first, from those that answer on
/// the network or by its address, then signs in on its account step, which shows the people the
/// server lists. Anyone who has signed in before starts on the account step: a server signed in
/// to on this device is picked already, and one on another of the person's devices signs in with
/// a tap, with the password saved in iCloud or for the password next (see `SignInFlow`). Signed
/// out, it offers the sign-ins still kept on this device, which switch without a password.
struct LoginView: View {
    /// A sign-in to start from, such as the one a handed-off title is from.
    var offer: ServerSignIn?
    /// Signs in beside the sign-in in use, starting from its server for someone else on it.
    var addsAccount = false

    @Environment(AccountStore.self) private var accounts
    @Environment(KnownServers.self) private var knownServers
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var flow = SignInFlow(deviceName: Device.name)
    @State private var check: ServerCheck?
    /// The sign-in under way. There's one at a time, and going Back or to another server, or
    /// editing the address it's for, takes it back.
    @State private var running: Running?
    @State private var quickConnect: QuickConnectPrompt?
    @State private var discovery = ServerDiscovery()
    /// The people the picked server lists on its sign-in screen, with the server they're on.
    @State private var publicUsers: (server: URL, users: [PublicUser])?
    /// The address's protocol, port and base path show.
    @State private var showsAdvanced = false
    @FocusState private var focus: SignInFlow.Field?
    /// The field the cursor moves to next, which comes into view first: a form draws only the
    /// rows on screen, and a field it hasn't drawn can't take the cursor.
    @State private var nextFocus: SignInFlow.Field?

    private struct Running {
        /// The attempt, at the address the server answered at once it has.
        var attempt: SignInFlow.Attempt
        var task: Task<Void, Never>
    }

    /// Whether a Jellyfin server answers at an address of the server step's, as it's typed or as
    /// a sign-in looks for the server there.
    struct ServerCheck {
        enum State {
            case checking
            /// It answered at the address, or else at its fallback.
            case found(AccountStore.Server, at: ServerAddress)
            case failed(SignInFlow.Trouble)
        }

        /// The address as the fields gave it.
        var address: ServerAddress
        var state: State

        /// The server found at `address`, with where it answered.
        func answer(at address: ServerAddress) -> (address: ServerAddress, answer: AccountStore.Server)? {
            guard address == self.address, case .found(let server, let answeredAt) = state else { return nil }
            return (answeredAt, server)
        }
    }

    /// A Quick Connect code waiting to be approved, on the server it's from.
    private struct QuickConnectPrompt: Identifiable {
        var code: String
        var server: String
        /// Approved and signed in, for a moment before the screen goes.
        var isSignedIn = false

        var id: String { code }
    }

    private static let quickConnectExplanation: LocalizedStringKey =
        "Quick Connect shows a code to approve in Jellyfin on a device that's already signed in, so there's no password to type."

    var body: some View {
        NavigationStack(path: steps) {
            stepForm(flow.root)
                .navigationDestination(for: SignInFlow.Step.self) { stepForm($0) }
        }
        #if !os(tvOS)
        // Closing the sheet takes back the sign-in under way.
        .onDisappear(perform: cancelSignIn)
        #endif
        .sheet(item: $quickConnect, onDismiss: cancelSignIn) { prompt in
            QuickConnectSheet(code: prompt.code, server: prompt.server, isSignedIn: prompt.isSignedIn, onCancel: cancelSignIn)
        }
        .onAppear {
            let next = flow.start(offer: offer, password: offer.flatMap { knownServers.password(for: $0) },
                                  adding: addsAccount ? accounts.account : nil, lastServerURL: accounts.lastServerURL,
                                  lastServerName: accounts.lastServerName, lastUserName: accounts.lastUserName,
                                  knowsServers: !knownServers.signIns.isEmpty || !accounts.saved.isEmpty)
            if let next { follow(next) }
        }
        .onChange(of: focus) { previous, _ in
            // A full address in the field fills in Advanced once it's done, so "nas:8096" isn't
            // cut apart at "nas:" while it's being typed.
            if previous == .host { flow.editAddress { $0.splitHost() } }
        }
        // Editing the address takes back the sign-in to the address as it was.
        .onChange(of: flow.address) {
            if let running, flow.isStale(running.attempt) { cancelSignIn() }
        }
        .task(id: flow.step == .server ? flow.address : nil) { await checkServer() }
        .task(id: flow.step == .account ? flow.pickedServer?.url : nil) { await loadPublicUsers() }
        // Said where they show, in the form's footers, away from VoiceOver's cursor.
        .onChange(of: flow.accountError) { _, error in if let error { announce(error) } }
        .onChange(of: flow.serverError) { _, error in if let error { announce(error) } }
    }

    /// The step on screen over the one the screen opens on, as the navigation stack shows it:
    /// Back, the swipe back and Menu on Apple TV go back to that one.
    private var steps: Binding<[SignInFlow.Step]> {
        Binding {
            flow.step == flow.root ? [] : [flow.step]
        } set: { path in
            if path.isEmpty, flow.step != flow.root { back() }
        }
    }

    private func stepForm(_ step: SignInFlow.Step) -> some View {
        ScrollViewReader { form in
            Form {
                switch step {
                case .account: accountStep
                case .server: serverStep
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title(of: step))
            #if os(iOS)
            .safeAreaBar(edge: .top) {
                if step == .server, pinsServerStatus { pinnedServerStatus }
            }
            #endif
            #if !os(tvOS)
            .toolbar {
                if step == flow.root {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { stepButton(step) }
            }
            #endif
            .onChange(of: nextFocus, initial: true) { _, field in
                guard let field, step == flow.step else { return }
                nextFocus = nil
                if field == .port || field == .path { showsAdvanced = true }
                form.scrollTo(field)
                focus = field
            }
            // While the server step shows, for servers on the network.
            .task(id: step == .server && flow.step == .server) {
                if step == .server, flow.step == .server { await discovery.searchWhileShown() }
            }
        }
    }

    private func title(of step: SignInFlow.Step) -> String {
        switch step {
        case .server: "Find Your Server"
        case .account: flow.pickedServer?.title ?? "Connect to Jellyfin"
        }
    }

    /// The step's button, which signs in or goes on to the next step: beside Cancel in the
    /// sheet's bar, and on Apple TV, whose sheet has no bar, in the form.
    @ViewBuilder private func stepButton(_ step: SignInFlow.Step) -> some View {
        switch step {
        case .account:
            Button(action: submitAccount) {
                title(flow.accountStepSignsIn ? "Sign In" : "Next",
                      isRunning: running.map { $0.attempt.goal != .quickConnect } ?? false)
            }
            .disabled(flow.trimmedUsername.isEmpty || running != nil)
            .accessibilityIdentifier("login.submit")
        case .server:
            Button(action: connect) {
                title(connectTitle, isRunning: running != nil)
            }
            .disabled(flow.address.host.trimmingCharacters(in: .whitespaces).isEmpty || running != nil)
            .accessibilityIdentifier("login.connect")
        }
    }

    // MARK: The account step

    @ViewBuilder private var accountStep: some View {
        if let users = shownUsers, !users.isEmpty {
            usersSection(users)
        }
        Section {
            TextField("Username", text: $flow.username)
                .textContentType(.username)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { nextFocus = .password }
                .accessibilityIdentifier("login.username")
                .id(SignInFlow.Field.username)
            SecureField("Password", text: $flow.password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(flow.accountStepSignsIn ? .go : .next)
                .onSubmit(submitAccount)
                .accessibilityIdentifier("login.password")
                .id(SignInFlow.Field.password)
            #if os(tvOS)
            stepButton(.account)
            #endif
            quickConnectButton
        } header: {
            Text("Account")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = flow.accountError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("login.error")
                }
                Text(Self.quickConnectExplanation)
            }
        }
        if let server = flow.pickedServer {
            Section {
                LabeledContent("Signing in to \(server.title)") {
                    Button("Change", action: changeServer)
                        .accessibilityIdentifier("login.changeServer")
                        .accessibilityValue(server.url.absoluteString)
                }
            }
        }
        keptSection
        knownServersSection
    }

    private var quickConnectButton: some View {
        Button(action: useQuickConnect) {
            title("Use Quick Connect", systemImage: "number.square", isRunning: running?.attempt.goal == .quickConnect)
        }
        .disabled(running != nil)
        .accessibilityIdentifier("login.quickConnect")
    }

    /// The people the picked server lists, once they've come.
    private var shownUsers: [PublicUser]? {
        guard let publicUsers, publicUsers.server == flow.pickedServer?.url else { return nil }
        return publicUsers.users
    }

    /// The people the server lists on its sign-in screen: one tap fills in the username, and
    /// signs in someone without a password.
    private func usersSection(_ users: [PublicUser]) -> some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: Self.userSpacing) {
                    ForEach(users) { user in
                        Button {
                            choose(user)
                        } label: {
                            PublicUserLabel(user: user, picture: flow.pickedServer.flatMap {
                                accounts.pictureURL(of: user, on: $0.url, points: Int(Self.userSide))
                            }, side: Self.userSide, isChosen: flow.trimmedUsername == user.name)
                        }
                        #if os(tvOS)
                        .buttonStyle(.borderless)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .accessibilityIdentifier("login.publicUser")
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        } header: {
            Text("Who's Signing In?")
        }
    }

    #if os(tvOS)
    private static let userSide: CGFloat = 140
    private static let userSpacing: CGFloat = 40
    #else
    private static let userSide: CGFloat = 64
    private static let userSpacing: CGFloat = 18
    #endif

    /// The sign-ins kept on this device but for the one in use: one tap uses it again.
    @ViewBuilder private var keptSection: some View {
        if !accounts.others.isEmpty {
            Section {
                ForEach(accounts.others, id: \.tokenKey) { account in
                    Button {
                        switchTo(account)
                    } label: {
                        Label("\(account.userName) on \(account.serverTitle)", systemImage: "person.crop.circle")
                    }
                    .contextMenu {
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { signOut(account) }
                    }
                    .accessibilityAction(named: "Sign Out") { signOut(account) }
                    .accessibilityIdentifier("login.keptAccount")
                }
            } header: {
                Text("Signed In on This \(Device.name)")
            } footer: {
                Text("Choosing one switches to it without a password.")
            }
        }
    }

    /// The servers signed in to on the person's devices, from iCloud, but for the sign-ins kept
    /// here: one tap picks the server and fills in the user, and the password or Quick Connect
    /// does the rest.
    @ViewBuilder private var knownServersSection: some View {
        let signIns = knownServers.signIns.filter { signIn in !accounts.saved.contains { signIn.isSignedIn(as: $0) } }
        if !signIns.isEmpty || knownServers.problem != nil {
            Section {
                ForEach(signIns) { signIn in
                    Button {
                        choose(signIn)
                    } label: {
                        Label("Sign in to \(signIn.serverTitle) as \(signIn.userName)", systemImage: "server.rack")
                    }
                    .contextMenu {
                        Button("Forget", systemImage: "trash", role: .destructive) { knownServers.forget(signIn) }
                    }
                    .accessibilityAction(named: "Forget") { knownServers.forget(signIn) }
                    .accessibilityIdentifier("login.knownServer")
                }
            } header: {
                Text("Your Servers")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Servers you've signed in to on your devices. Choosing one signs in with the password saved in iCloud; without one, enter the password or use Quick Connect.")
                    if let problem = knownServers.problem {
                        Text(problem).foregroundStyle(.orange)
                        Button("Dismiss") { knownServers.problem = nil }
                    }
                }
            }
        }
    }

    // MARK: The server step

    @ViewBuilder private var serverStep: some View {
        #if os(tvOS)
        if flow.root == .server {
            Section {
                HStack(spacing: 32) {
                    AppMark(size: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("vinnyfin").font(.title2.weight(.bold))
                        Text("Your Jellyfin library, on this Apple TV.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        #endif
        discoveredSection
        Section {
            TextField("Server Address", text: Binding { flow.addressText } set: { flow.typeAddress($0) },
                      prompt: Text("http://192.168.1.10:8096 or jf.example.com"))
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .host)
                .submitLabel(showsAdvanced ? .next : .go)
                .onSubmit { if showsAdvanced { nextFocus = .port } else { connect() } }
                .accessibilityIdentifier("login.host")
                .id(SignInFlow.Field.host)
            #if os(tvOS)
            Button {
                showsAdvanced.toggle()
            } label: {
                LabeledContent("Advanced") {
                    Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                }
            }
            .accessibilityIdentifier("login.advanced")
            if showsAdvanced { advancedFields }
            #else
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) { advancedFields }
                .accessibilityIdentifier("login.advanced")
            #endif
        } header: {
            // Above the fields, where the keyboard doesn't cover it, or on a short screen, under
            // the bar.
            VStack(alignment: .leading, spacing: 4) {
                Text("Server Address")
                if !pinsServerStatus {
                    serverStatus
                        .textCase(nil)
                }
            }
        } footer: {
            if flow.isQuickConnect {
                Text(Self.quickConnectExplanation)
            } else if !flow.trimmedUsername.isEmpty {
                Text("Signs in as \(flow.trimmedUsername).")
            }
        }
        #if os(tvOS)
        Section { stepButton(.server) }
        #endif
        if offersHTTP {
            Section {
                Button("Use HTTP", systemImage: "lock.open", action: useHTTP)
                    .accessibilityIdentifier("login.useHTTP")
            }
        }
        if flow.offersPassword {
            Section {
                Button("Sign In with a Password", systemImage: "key", action: usePassword)
                    .accessibilityIdentifier("login.usePassword")
            }
        }
        if flow.root == .server {
            if flow.trimmedUsername.isEmpty {
                Section {
                    Button("Sign In with a Username", systemImage: "person.text.rectangle", action: useUsernameFirst)
                        .accessibilityIdentifier("login.usernameFirst")
                } footer: {
                    Text("Enter your username and password first, and the server's address after.")
                }
            }
            keptSection
            knownServersSection
        }
    }

    /// The address's protocol, port and base path, which the address field fills in.
    @ViewBuilder private var advancedFields: some View {
        Picker("Protocol", selection: Binding { flow.address.givenScheme } set: { scheme in flow.editAddress { $0.choose(scheme) } }) {
            Text("Automatic").tag(ServerAddress.Scheme?.none)
            Text("HTTP").tag(ServerAddress.Scheme?.some(.http))
            Text("HTTPS").tag(ServerAddress.Scheme?.some(.https))
        }
        .accessibilityIdentifier("login.scheme")
        LabeledContent("Port") {
            TextField("Port", text: Binding { flow.address.port } set: { port in flow.editAddress { $0.port = port } },
                      prompt: Text(flow.address.givenScheme.map { String($0.defaultPort) } ?? "Automatic"))
                .labelsHidden()
                #if !os(macOS)
                // Has a return key, unlike the number pad.
                .keyboardType(.numbersAndPunctuation)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .port)
                .submitLabel(.next)
                .onSubmit { nextFocus = .path }
                .accessibilityIdentifier("login.port")
        }
        .id(SignInFlow.Field.port)
        LabeledContent("Base Path") {
            TextField("Base Path", text: Binding { flow.address.path } set: { path in flow.editAddress { $0.path = path } },
                      prompt: Text("Optional, e.g. /jellyfin"))
                .labelsHidden()
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .path)
                .submitLabel(.go)
                .onSubmit(connect)
                .accessibilityIdentifier("login.path")
        }
        .id(SignInFlow.Field.path)
    }

    /// The servers that answered on the network, while the system lets the app ask
    /// (`ServerDiscovery`): one tap finds the server, then asks who's signing in.
    @ViewBuilder private var discoveredSection: some View {
        if discovery.isAvailable == true {
            Section {
                ForEach(discovery.servers) { server in
                    Button {
                        pick(server)
                    } label: {
                        LabeledContent {
                            Text(SignInFlow.title(of: server.address))
                        } label: {
                            Label(server.name, systemImage: "server.rack")
                        }
                    }
                    .disabled(running != nil)
                    .accessibilityIdentifier("login.discovered")
                }
                if discovery.servers.isEmpty {
                    if discovery.isSearching {
                        Label {
                            Text("Looking on your network…")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text("No servers answered on this network. Enter your server's address below.")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("On Your Network")
            }
        }
    }

    /// Whether the server's status goes under the bar rather than over the fields: on a screen
    /// as short as an iPhone's on its side, the form scrolls the fields' header away to keep the
    /// one being typed in above the keyboard.
    private var pinsServerStatus: Bool {
        #if os(iOS)
        flow.step == .server && verticalSizeClass == .compact
        #else
        false
        #endif
    }

    /// The address as a URL, then why it didn't do, or else whether a server answers at it.
    private var serverStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .success(let url) = flow.address.url {
                Text(url.absoluteString).monospaced()
            }
            serverAnswer
        }
        #if !os(tvOS)
        .textSelection(.enabled)
        #endif
    }

    #if os(iOS)
    /// The status under the bar, a line high even with nothing to say: were it to grow when the
    /// answer comes, the field being typed in would slide down behind the keyboard.
    private var pinnedServerStatus: some View {
        ZStack(alignment: .leading) {
            Label("Server", systemImage: "checkmark.circle.fill").hidden()
            serverAnswer
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
    }
    #endif

    /// Why the address didn't do, or else whether a server answers at it.
    @ViewBuilder private var serverAnswer: some View {
        if let error = flow.serverError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("login.error")
        } else if let check, check.address == flow.address {
            switch check.state {
            case .checking:
                Label {
                    Text("Looking for the server…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .accessibilityIdentifier("login.checking")
            case .found(let server, _):
                Label(description(of: server), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("login.found")
            case .failed(let trouble):
                Label(trouble.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The server step's address failed on HTTPS, which it gives, so HTTP is offered: the
    /// sign-in's error says so, or else the check of the address as it's typed.
    private var offersHTTP: Bool {
        if flow.serverError != nil { return flow.offersHTTP }
        guard let check, check.address == flow.address, case .failed(let trouble) = check.state else { return false }
        return trouble.offersHTTP
    }

    /// "Found Home (Jellyfin 10.11.0)", and where, when it's not at the address as the fields
    /// have it.
    private func description(of server: AccountStore.Server) -> String {
        let version = server.info.version.map { " (Jellyfin \($0))" } ?? ""
        let isAtTheFields = if case .success(let url) = flow.address.url { url == server.url } else { false }
        return "Found \(server.title)\(version)\(isAtTheFields ? "" : " at \(server.url.absoluteString)")"
    }

    private var connectTitle: LocalizedStringKey {
        if flow.isQuickConnect { return "Get Code" }
        return flow.trimmedUsername.isEmpty ? "Next" : "Sign In"
    }

    /// A button's title, followed by a spinner while the sign-in it started is under way.
    private func title(_ text: LocalizedStringKey, systemImage: String? = nil, isRunning: Bool) -> some View {
        HStack {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private func submitAccount() {
        guard running == nil else { return }
        follow(flow.submitAccount())
    }

    private func useQuickConnect() {
        guard running == nil else { return }
        follow(flow.useQuickConnect())
    }

    private func connect() {
        guard running == nil else { return }
        follow(flow.connect())
    }

    private func pick(_ server: DiscoveredServer) {
        guard running == nil else { return }
        follow(flow.pick(server))
    }

    private func choose(_ user: PublicUser) {
        guard running == nil else { return }
        follow(flow.chooseUser(user))
    }

    /// A server signed in to on the person's devices: this device's own sign-in to it, kept here,
    /// switches to it; any other picks the server and fills in the user.
    private func choose(_ signIn: ServerSignIn) {
        cancelSignIn()
        if let kept = accounts.saved.first(where: { signIn.isSignedIn(as: $0) }) {
            switchTo(kept)
            return
        }
        if let next = flow.choose(signIn, password: knownServers.password(for: signIn)) { follow(next) }
    }

    private func switchTo(_ account: AccountStore.Account) {
        cancelSignIn()
        do {
            try accounts.switchTo(account)
            dismiss()
        } catch {
            flow.showAccountError(error.localizedDescription)
        }
    }

    private func signOut(_ account: AccountStore.Account) {
        #if os(tvOS)
        accounts.signOut(of: account)
        #else
        accounts.signOut(of: account, cancelling: downloads)
        #endif
    }

    private func changeServer() {
        cancelSignIn()
        nextFocus = flow.changeServer()
    }

    private func useUsernameFirst() {
        cancelSignIn()
        nextFocus = flow.useUsernameFirst()
    }

    private func back() {
        cancelSignIn()
        flow.back()
    }

    private func usePassword() {
        cancelSignIn()
        nextFocus = flow.usePassword()
    }

    private func useHTTP() {
        flow.useHTTP()
    }

    private func follow(_ next: SignInFlow.Next) {
        switch next {
        case .focus(let field):
            nextFocus = field
        case .attempt(let attempt):
            let task = Task {
                await run(attempt)
                // A sign-in taken back has made way for the next already.
                if !Task.isCancelled { running = nil }
            }
            running = Running(attempt: attempt, task: task)
        }
    }

    private func cancelSignIn() {
        running?.task.cancel()
        running = nil
        quickConnect = nil
    }

    /// Finds the server, unless the check of the address as it was typed just has, then signs in
    /// to it with the password, or shows a Quick Connect code and waits for its approval.
    private func run(_ attempt: SignInFlow.Attempt) async {
        let found: (address: ServerAddress, answer: AccountStore.Server)
        if let checked = check?.answer(at: attempt.address) {
            found = checked
        } else {
            if flow.step == .server, flow.address == attempt.address {
                check = ServerCheck(address: attempt.address, state: .checking)
            }
            do {
                found = try await attempt.address.firstAnswer { try await accounts.findServer(at: $0) }
            } catch {
                fail(attempt, while: .findingServer, with: error)
                return
            }
            guard !Task.isCancelled else { return }
        }
        let server = found.answer
        let going: SignInFlow.Attempt
        switch flow.found(server, at: found.address, for: attempt) {
        case .stale:
            return
        case .picked(let field):
            check = ServerCheck(address: found.address, state: .found(server, at: found.address))
            nextFocus = field
            return
        case .signIn(let answered):
            going = answered
        }
        // The fields hold the address that answered now, where the sign-in goes on.
        running?.attempt = going
        if !going.isDemo { check = ServerCheck(address: going.address, state: .found(server, at: going.address)) }
        do {
            switch going.goal {
            case .server:
                return
            case .password(let username, let password):
                try await accounts.signIn(to: server, username: username, password: password)
                if let account = accounts.account { knownServers.signedIn(as: account, with: password) }
            case .quickConnect:
                let state = try await accounts.startQuickConnect(on: server)
                guard !Task.isCancelled else { return }
                quickConnect = QuickConnectPrompt(code: state.code, server: server.title)
                try await accounts.finishQuickConnect(on: server, secret: state.secret) {
                    quickConnect?.isSignedIn = true
                    try await Task.sleep(for: Self.signedInMoment)
                }
            }
        } catch {
            fail(going, while: .signingIn, with: error)
            return
        }
        guard !Task.isCancelled else { return }
        quickConnect = nil
        dismiss()
    }

    /// How long the Quick Connect code says it's signed in before the screen goes.
    private static let signedInMoment = Duration.seconds(1)

    private func fail(_ attempt: SignInFlow.Attempt, while stage: SignInFlow.Stage, with error: any Error) {
        guard !Task.isCancelled, !error.isCancellation else { return }
        quickConnect = nil
        if let field = flow.fail(attempt, while: stage, with: error) { nextFocus = field }
    }

    private func checkServer() async {
        guard flow.step == .server, case .success = flow.address.url else {
            check = nil
            return
        }
        // Found there already, by the sign-in that put the address in the fields.
        if check?.answer(at: flow.address) != nil { return }
        // Wait for typing to settle; a newer address cancels this check.
        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }
        let address = flow.address
        check = ServerCheck(address: address, state: .checking)
        do {
            let found = try await address.firstAnswer { try await accounts.findServer(at: $0) }
            check = ServerCheck(address: address, state: .found(found.answer, at: found.address))
            announce(description(of: found.answer))
        } catch {
            if !Task.isCancelled, !error.isCancellation {
                let trouble = SignInFlow.trouble(error, at: address, on: Device.name)
                check = ServerCheck(address: address, state: .failed(trouble))
                announce(trouble.message)
            }
        }
    }

    /// The people the picked server lists on its sign-in screen. A server that lists no one, or
    /// can't be asked, shows no one.
    private func loadPublicUsers() async {
        guard flow.step == .account, let server = flow.pickedServer?.url else { return }
        if publicUsers?.server == server { return }
        do {
            let users = try await accounts.publicUsers(on: server)
            publicUsers = (server, users)
        } catch {
            publicUsers = (server, [])
        }
    }
}

/// Someone a server lists: their picture, or their initial without one, and their name.
private struct PublicUserLabel: View {
    let user: PublicUser
    let picture: URL?
    let side: CGFloat
    let isChosen: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.tint.opacity(0.18))
                Text(user.name.prefix(1).uppercased())
                    .font(.system(size: side * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
                if let picture {
                    AsyncImage(url: picture) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .clipShape(.circle)
                }
            }
            .frame(width: side, height: side)
            .overlay {
                if isChosen { Circle().strokeBorder(.tint, lineWidth: 3) }
            }
            Text(user.name)
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: side + 16)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(user.name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// The Quick Connect code, shown large while waiting for it to be approved, and then for a moment
/// that it's signed in.
private struct QuickConnectSheet: View {
    let code: String
    /// What the server is called.
    let server: String
    let isSignedIn: Bool
    let onCancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Quick Connect").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("On \(server)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("login.quickConnectServer")
            }
            Text("In Jellyfin on a signed-in device, open your profile, choose Quick Connect and enter this code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Text(code)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .kerning(8)
                // A digit at a time, as it's typed in, rather than as one number.
                .speechSpellsOutCharacters()
                .accessibilityIdentifier("login.quickConnectCode")
            if isSignedIn {
                Label("Signed In", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityIdentifier("login.quickConnectSignedIn")
            } else {
                ProgressView("Waiting for approval…")
            }
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.platformGlass)
                .disabled(isSignedIn)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .animation(.default, value: isSignedIn)
        .sensoryFeedback(.success, trigger: isSignedIn)
        .onChange(of: isSignedIn) { _, signedIn in if signedIn { announce("Signed in to \(server)") } }
        // The whole screen for text too large for half of it.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium])
    }
}
