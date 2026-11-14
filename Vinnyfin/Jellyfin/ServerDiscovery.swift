import Darwin
import Foundation
import Observation
import OSLog

/// A Jellyfin server that answered on the local network, as it describes itself.
nonisolated struct DiscoveredServer: Hashable, Identifiable, Sendable {
    /// The server's id, as its sign-ins give it.
    let id: String
    let name: String
    /// Where the server says it is, as its administrator set it up.
    let address: URL

    init(id: String, name: String, address: URL) {
        self.id = id
        self.name = name
        self.address = address
    }

    /// The server a reply to Jellyfin's discovery describes: JSON like
    /// `{"Address":"http://192.168.1.10:8096","Id":"…","Name":"Home","EndpointAddress":null}`.
    /// Nil for anything else, or an address that isn't a web one.
    init?(reply: Data) {
        struct Reply: Decodable {
            let address: String?
            let id: String?
            let name: String?

            enum CodingKeys: String, CodingKey {
                case address = "Address", id = "Id", name = "Name"
            }
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: reply),
              let id = reply.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let text = reply.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let address = components.url else { return nil }
        let name = reply.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: id, name: name.isEmpty ? host : name, address: address)
    }
}

/// Finds the Jellyfin servers on the local network as Jellyfin's own apps do: it broadcasts
/// "who is JellyfinServer?" to UDP port 7359, which each server answers with its name, id and
/// address.
///
/// iPhone, iPad, Apple TV and Vision Pro send a broadcast only for an app Apple has granted the
/// multicast networking entitlement (`com.apple.developer.networking.multicast`); for any other,
/// the system refuses to send it, and discovery is unavailable (`isAvailable`), leaving the
/// address to type. The Mac needs no entitlement. It asks this device as well, for a server
/// running on it, which a Mac and the Simulator can have.
@Observable
final class ServerDiscovery {
    /// The servers that answered, by name.
    private(set) var servers: [DiscoveredServer] = []
    private(set) var isSearching = false
    /// Whether the system sent the last search's broadcast. Nil until a search has asked.
    private(set) var isAvailable: Bool?

    nonisolated static let port: UInt16 = 7359
    nonisolated static let question = "who is JellyfinServer?"
    /// How long a search waits for answers. A server on the network answers in milliseconds.
    static let listenTime = Duration.seconds(2)
    /// How long after a search the next one asks, for a server just turned on, or for the system
    /// that just let the app onto the local network.
    static let searchInterval = Duration.seconds(8)

    nonisolated private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "discovery")

    /// Searches, then again every `searchInterval`, until the calling task is cancelled.
    func searchWhileShown() async {
        while !Task.isCancelled {
            await search()
            try? await Task.sleep(for: Self.searchInterval)
        }
    }

    /// Asks once, and takes the answers that come within `listenTime`.
    func search() async {
        isSearching = true
        defer { isSearching = false }
        do {
            for try await event in Self.answers(within: Self.listenTime) {
                switch event {
                case .asked: isAvailable = true
                case .answered(let server): take(server)
                }
            }
        } catch let refusal as DiscoveryRefused {
            if isAvailable != false {
                Self.log.notice("The system didn't send the discovery broadcast: \(refusal.localizedDescription, privacy: .public)")
            }
            isAvailable = false
        } catch {
            Self.log.error("Discovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the server, or what it says of itself now, once.
    func take(_ server: DiscoveredServer) {
        servers.removeAll { $0.id == server.id }
        servers.append(server)
        servers.sort { ($0.name.localizedLowercase, $0.address.absoluteString) < ($1.name.localizedLowercase, $1.address.absoluteString) }
    }

    /// What a search hears.
    nonisolated enum Event: Sendable {
        /// The system sent the broadcast.
        case asked
        case answered(DiscoveredServer)
    }

    /// The broadcast going out, then the servers that answer it within `duration`. Throws
    /// `DiscoveryRefused` when the system sends the broadcast nowhere.
    nonisolated static func answers(within duration: Duration) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try ask(within: duration) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Broadcasts the question on every network the device is on, and asks the device itself,
    /// then hands over each answer until `duration` is up or the task is cancelled. Blocks.
    nonisolated private static func ask(within duration: Duration, hear: (Event) -> Void) throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(socket) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let question = Array(Self.question.utf8)
        var broadcastSent = false
        var refusal: Int32 = 0
        for destination in destinations() {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: destination.address)
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, question, question.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent >= 0 {
                broadcastSent = broadcastSent || destination.isBroadcast
            } else if destination.isBroadcast {
                refusal = errno
            }
        }
        guard broadcastSent else { throw DiscoveryRefused(code: refusal) }
        hear(.asked)

        let deadline = ContinuousClock.now + duration
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let server = DiscoveredServer(reply: Data(buffer[..<count])) { hear(.answered(server)) }
        }
    }

    /// Where the question goes, in network byte order: everywhere on the network the system
    /// routes a broadcast to, each network's own broadcast address, and this device.
    nonisolated private static func destinations() -> [(address: in_addr_t, isBroadcast: Bool)] {
        var destinations: [(address: in_addr_t, isBroadcast: Bool)] = [(in_addr_t(0xffff_ffff), true)]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0, let first = interfaces {
            defer { freeifaddrs(interfaces) }
            for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(interface.pointee.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                      let address = interface.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                      let broadcast = interface.pointee.ifa_dstaddr
                else { continue }
                let target = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if target != 0, !destinations.contains(where: { $0.address == target }) { destinations.append((target, true)) }
            }
        }
        destinations.append((in_addr_t(0x7f00_0001).bigEndian, false))
        return destinations
    }
}

/// The system sent the discovery broadcast nowhere: on iPhone, iPad, Apple TV and Vision Pro, as
/// for an app without the multicast networking entitlement, or with no network to send it on.
nonisolated struct DiscoveryRefused: LocalizedError {
    let code: Int32

    var errorDescription: String? {
        "\(String(cString: strerror(code))) (\(code))"
    }
}
