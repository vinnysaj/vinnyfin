import SwiftUI

/// Signs in to a Jellyfin server, asking for the account first and the server second: a server
/// signed in to before, on this device or another of the person's, signs in with a tap, with the
/// password saved in iCloud or for the password next, and any other is asked for by its address
/// once the account is in (see `SignInFlow`).
struct LoginView: View {
    /// A sign-in to start from, such as the one a handed-off title is from.
    var offer: ServerSignIn?

    @Environment(AccountStore.self) private var accounts
    @Environment(KnownServers.self) private var knownServers
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
        "Shows a code to approve in Jellyfin on a device that's already signed in, so there's no password to type."

    var body: some View {
        NavigationStack {
            ScrollViewReader { form in
                Form {
                    switch flow.step {
                    case .account: accountStep
                    case .server: serverStep
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Connect to Jellyfin")
                #if os(iOS)
                .safeAreaBar(edge: .top) {
                    if pinsServerStatus { pinnedServerStatus }
                }
                #endif
                #if os(tvOS)
                .onExitCommand(perform: exitCommand)
                #else
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) { stepButton }
                }
                // Closing the sheet takes back the sign-in under way.
                .onDisappear(perform: cancelSignIn)
                #endif
                .sheet(item: $quickConnect, onDismiss: cancelSignIn) { prompt in
                    QuickConnectSheet(code: prompt.code, server: prompt.server, isSignedIn: prompt.isSignedIn, onCancel: cancelSignIn)
                }
                .onAppear {
                    if let next = flow.start(offer: offer, password: offer.flatMap { knownServers.password(for: $0) },
                                             lastServerURL: accounts.lastServerURL, lastServerName: accounts.lastServerName,
                                             lastUserName: accounts.lastUserName) {
                        follow(next)
                    }
                }
                .onChange(of: focus) { previous, _ in
                    // A full address in the host field fills in the other fields once the host is
                    // done, so "nas:8096" isn't cut apart at "nas:" while it's being typed.
                    if previous == .host { flow.address.splitHost() }
                }
                // Editing the address takes back the sign-in to the address as it was.
                .onChange(of: flow.address) {
                    if let running, flow.isStale(running.attempt) { cancelSignIn() }
                }
                .task(id: flow.step == .server ? flow.address : nil) { await checkServer() }
                // Said where they show, in the form's footers, away from VoiceOver's cursor.
                .onChange(of: flow.accountError) { _, error in if let error { announce(error) } }
                .onChange(of: flow.serverError) { _, error in if let error { announce(error) } }
                .onChange(of: nextFocus) { _, field in
                    guard let field else { return }
                    nextFocus = nil
                    form.scrollTo(field)
                    focus = field
                }
            }
        }
    }

    #if os(tvOS)
    /// Menu on the server step goes back to the account step. The account step is the app's first
    /// screen, so there Menu leaves the app as usual.
    private var exitCommand: (@MainActor () -> Void)? {
        flow.step == .server ? back : nil
    }
    #endif

    /// The step's button, which signs in or goes on to the next step: beside Cancel in the
    /// sheet's bar, and on Apple TV, whose sheet has no bar, in the form.
    @ViewBuilder private var stepButton: some View {
        switch flow.step {
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
        } header: {
            Text("Account")
        } footer: {
            if let error = flow.accountError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("login.error")
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
        #if os(tvOS)
        Section { stepButton }
        #endif
        Section {
            Button(action: useQuickConnect) {
                title("Use Quick Connect", systemImage: "number.square", isRunning: running?.attempt.goal == .quickConnect)
            }
            .disabled(running != nil)
            .accessibilityIdentifier("login.quickConnect")
        } footer: {
            Text(Self.quickConnectExplanation)
        }
        knownServersSection
    }

    /// The servers signed in to on the person's devices, from iCloud: one tap picks the server
    /// and fills in the user, and the password or Quick Connect does the rest.
    @ViewBuilder private var knownServersSection: some View {
        if !knownServers.signIns.isEmpty || knownServers.problem != nil {
            Section {
                ForEach(knownServers.signIns) { signIn in
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
        Section {
            Picker("Protocol", selection: Binding { flow.address.scheme } set: { flow.address.choose($0) }) {
                Text("HTTP").tag(ServerAddress.Scheme.http)
                Text("HTTPS").tag(ServerAddress.Scheme.https)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("login.scheme")
            LabeledContent("Host") {
                TextField("Host", text: $flow.address.host, prompt: Text("192.168.1.10 or jf.example.com"))
                    .labelsHidden()
                    .textContentType(.URL)
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { nextFocus = .port }
                    .accessibilityIdentifier("login.host")
            }
            .id(SignInFlow.Field.host)
            LabeledContent("Port") {
                TextField("Port", text: $flow.address.port, prompt: Text(String(flow.address.scheme.defaultPort)))
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
                TextField("Base Path", text: $flow.address.path, prompt: Text("Optional, e.g. /jellyfin"))
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
        } header: {
            // Above the fields, where the keyboard doesn't cover it, or on a short screen, under
            // the bar.
            VStack(alignment: .leading, spacing: 4) {
                Text("Server")
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
        Section { stepButton }
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
        Section {
            Button("Back", systemImage: "chevron.backward", action: back)
                .accessibilityIdentifier("login.back")
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

    private func choose(_ signIn: ServerSignIn) {
        cancelSignIn()
        if let next = flow.choose(signIn, password: knownServers.password(for: signIn)) { follow(next) }
    }

    private func changeServer() {
        cancelSignIn()
        nextFocus = flow.changeServer()
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
