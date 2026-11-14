import Foundation

/// A Jellyfin server address as the sign-in form edits it: protocol, host, port and base path.
nonisolated struct ServerAddress: Equatable, Sendable {
    enum Scheme: String, CaseIterable, Sendable {
        case http, https

        /// Jellyfin listens on 8096 for HTTP; HTTPS is usually a reverse proxy on 443.
        var defaultPort: Int { self == .http ? 8096 : 443 }
    }

    /// What's wrong with an address, which says the field to put it right in.
    enum Problem: LocalizedError, Equatable {
        case missingHost
        case invalidHost(String)
        case invalidPort
        case invalidAddress

        var errorDescription: String? {
            switch self {
            case .missingHost: "Enter the server's host name or IP address."
            case .invalidHost(let host): "“\(host)” isn't a host name or IP address."
            case .invalidPort: "The port has to be a number from 1 to 65535."
            case .invalidAddress: "That address isn't valid."
            }
        }
    }

    private(set) var scheme = Scheme.https
    /// Whether the scheme was given, by picking it, typing it with the address or saving it, rather
    /// than assumed. An address that doesn't give one may be on HTTP instead (see `fallback`).
    private(set) var isSchemeGiven = false
    var host = ""
    /// Empty means the scheme's default port.
    var port = ""
    /// Empty, or the base URL Jellyfin is configured with, e.g. "/jellyfin".
    var path = ""

    /// An address on `scheme`, or without a scheme, on HTTPS until it's given.
    init(scheme: Scheme? = nil, host: String = "", port: String = "", path: String = "") {
        self.scheme = scheme ?? .https
        isSchemeGiven = scheme != nil
        self.host = host
        self.port = port
        self.path = path
    }

    /// Splits a full address someone typed or pasted ("jf.example.com:8920/jellyfin",
    /// "https://10.0.0.5/jf/"), or copied from a browser showing Jellyfin's web app, which is at
    /// "web" under the base path: that, and what follows it, go
    /// ("https://jf.example.com/jellyfin/web/index.html#!/home" is at "/jellyfin"). Without a
    /// scheme, it's on HTTPS until one is given.
    init?(parsing text: String) {
        self.init(text, path: Self.basePath(ofWebAppPath:))
    }

    /// A server's saved URL, as the form shows it, its path the base path as it is. A saved HTTP
    /// address without a port is on port 80, not the form's default of 8096.
    init?(savedURL url: URL) {
        guard var address = ServerAddress(url.absoluteString, path: Self.normalizedPath) else { return nil }
        if url.port == nil { address.port = address.scheme == .http ? "80" : "" }
        self = address
    }

    /// An address from its text, with what `basePath` makes of the URL's path as its base path.
    private init?(_ text: String, path basePath: (String) -> String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = text.contains("://")
        if !hasScheme { text = "\(Scheme.https.rawValue)://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              let host = components.host, !host.isEmpty
        else { return nil }
        self.scheme = scheme
        isSchemeGiven = hasScheme
        self.host = host
        port = components.port.map(String.init) ?? ""
        path = basePath(components.path)
    }

    /// Picks the scheme, as the form's protocol does.
    mutating func choose(_ scheme: Scheme) {
        self.scheme = scheme
        isSchemeGiven = true
    }

    /// Splits a full address typed into the host field into the fields; the scheme, port and path
    /// already entered stay unless the address has its own.
    mutating func splitHost() {
        guard Self.looksLikeFullAddress(host), let parsed = ServerAddress(parsing: host) else { return }
        if parsed.isSchemeGiven { choose(parsed.scheme) }
        host = parsed.host
        if !parsed.port.isEmpty { port = parsed.port }
        if !parsed.path.isEmpty { path = parsed.path }
    }

    /// Whether the text looks like more than a bare host name, so it should be split up.
    static func looksLikeFullAddress(_ text: String) -> Bool {
        text.contains("://") || text.contains("/") || text.filter { $0 == ":" }.count == 1
    }

    var portNumber: Int? {
        port.isEmpty ? scheme.defaultPort : Int(port)
    }

    /// The base URL, or what's wrong with the address.
    var url: Result<URL, Problem> {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(.missingHost) }
        guard host.rangeOfCharacter(from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":/?#@"))) == nil else {
            return .failure(.invalidHost(host))
        }
        guard let portNumber, (1...65535).contains(portNumber) else { return .failure(.invalidPort) }
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        if portNumber != (scheme == .http ? 80 : 443) { components.port = portNumber }
        components.path = Self.normalizedPath(path)
        guard let url = components.url else { return .failure(.invalidAddress) }
        return .success(url)
    }

    /// The same server on HTTP, for an address that doesn't give a scheme: on the port it gives, or
    /// on Jellyfin's own 8096 without one. HTTPS is usually a reverse proxy's on 443, and Jellyfin
    /// itself answers HTTP on 8096, so a host alone may be on either, as may "nas.local:8096".
    var fallback: ServerAddress? {
        guard !isSchemeGiven else { return nil }
        return ServerAddress(scheme: .http, host: host, port: port, path: path)
    }

    /// How long a server has to answer before it counts as not answering. One on the same network
    /// answers in well under a second, and one across the internet in a second or two.
    static let answerTimeLimit = Duration.seconds(6)
    /// How much longer than HTTP an answer on HTTPS is waited for: a server that answers on both
    /// is found on HTTPS, rather than on HTTP for having answered there first.
    static let httpsGrace = Duration.seconds(1)

    /// What `ask` gets from the server at this address, or when nothing answers there, at its
    /// fallback, with the address that answered. Only an address at which nothing answers within
    /// `answerTimeLimit` moves on: a server that answers with an error, or isn't Jellyfin, has
    /// answered. Both are asked at once, and the fallback's answer stands once this address has
    /// had `httpsGrace` longer to answer. When the fallback doesn't answer either, the error is
    /// this address's own, as the one the form shows.
    func firstAnswer<Answer: Sendable>(
        _ ask: @escaping @MainActor (URL) async throws -> Answer
    ) async throws -> (address: ServerAddress, answer: Answer) {
        let first = try url.get()
        let timeLimit = Self.answerTimeLimit
        guard let fallback, case .success(let second) = fallback.url else {
            return (self, try await withTimeLimit(timeLimit) { try await ask(first) })
        }
        return try await withThrowingTaskGroup(of: Probe<Answer>.self) { group in
            defer { group.cancelAll() }
            group.addTask { .first(await Probe<Answer>.outcome { try await withTimeLimit(timeLimit) { try await ask(first) } }) }
            group.addTask { .fallback(await Probe<Answer>.outcome { try await withTimeLimit(timeLimit) { try await ask(second) } }) }
            var unanswered: URLError?
            var fallbackAnswer: Answer?
            var fallbackFailed = false
            while let probe = try await group.next() {
                switch probe {
                case .first(.success(let answer)):
                    return (self, answer)
                case .first(.failure(let error)):
                    guard let error = error as? URLError, error.code != .cancelled else { throw error }
                    if let fallbackAnswer { return (fallback, fallbackAnswer) }
                    if fallbackFailed { throw error }
                    unanswered = error
                case .fallback(.success(let answer)):
                    if unanswered != nil { return (fallback, answer) }
                    fallbackAnswer = answer
                    group.addTask {
                        try await Task.sleep(for: Self.httpsGrace)
                        return .graceOver
                    }
                case .fallback(.failure):
                    if let unanswered { throw unanswered }
                    fallbackFailed = true
                case .graceOver:
                    if let fallbackAnswer { return (fallback, fallbackAnswer) }
                }
            }
            throw CancellationError()
        }
    }

    /// What one of `firstAnswer`'s questions came to.
    private enum Probe<Answer: Sendable>: Sendable {
        case first(Result<Answer, any Error>)
        case fallback(Result<Answer, any Error>)
        /// The fallback answered, and this address has had `httpsGrace` longer to.
        case graceOver

        static func outcome(of question: () async throws -> Answer) async -> Result<Answer, any Error> {
            do {
                return .success(try await question())
            } catch {
                return .failure(error)
            }
        }
    }

    /// The base path of a path in Jellyfin's web app: what's before its last "web".
    private static func basePath(ofWebAppPath path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let web = segments.lastIndex(where: { $0.caseInsensitiveCompare("web") == .orderedSame }) else {
            return normalizedPath(path)
        }
        return normalizedPath(segments[..<web].joined(separator: "/"))
    }

    /// "" or "/base/path": a leading slash and no trailing one.
    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : "/" + trimmed
    }
}
