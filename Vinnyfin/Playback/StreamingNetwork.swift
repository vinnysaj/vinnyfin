import Foundation
import Network
import Synchronization

/// The network a stream would go over, as far as what it costs: whether streams keep to the
/// cellular streaming quality on it (`AppSettings.streamingQuality(on:)`).
nonisolated enum StreamingNetwork: Equatable, Sendable {
    /// Wi-Fi or Ethernet, with Low Data Mode off.
    case unmetered
    /// Cellular data, or a Personal Hotspot.
    case expensive
    /// Low Data Mode, on any network.
    case lowData

    init(isExpensive: Bool, isConstrained: Bool) {
        self = isConstrained ? .lowData : isExpensive ? .expensive : .unmetered
    }

    /// Streams on it keep to the cellular streaming quality.
    var savesData: Bool { self != .unmetered }

    /// The network the device is on. Apple TV has neither cellular data nor Low Data Mode.
    static var current: StreamingNetwork {
        #if os(tvOS)
        .unmetered
        #else
        let path = monitor.currentPath
        return StreamingNetwork(isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        #endif
    }

    /// The device is on cellular data or a Personal Hotspot, in Low Data Mode or not: not the
    /// connection it's usually on, which Adaptive Quality learns (`QualityLearning`) and steps
    /// back up on. Low Data Mode alone leaves the connection what it was.
    static var isExpensive: Bool {
        #if os(tvOS)
        false
        #else
        monitor.currentPath.isExpensive
        #endif
    }

    /// Starts following the network, so it's known by the first stream: until the monitor's
    /// first update its path says nothing.
    static func follow() {
        _ = monitor
    }

    /// Each time the device moves to another network, or loses or regains one, from now until
    /// the stream is let go: a server out of reach on one network may answer on the next.
    static func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        watchers.withLock { $0.waiting[id] = continuation }
        continuation.onTermination = { _ in watchers.withLock { _ = $0.waiting.removeValue(forKey: id) } }
        _ = monitor
        return stream
    }

    /// The streams of `changes()`, and the path last seen, which a change is told against.
    private struct Watchers {
        var waiting: [UUID: AsyncStream<Void>.Continuation] = [:]
        var path: NWPath?
    }

    private static let watchers = Mutex(Watchers())

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            watchers.withLock { watchers in
                // The first path is where the device already was, not a change.
                defer { watchers.path = path }
                guard let last = watchers.path, last != path else { return }
                for continuation in watchers.waiting.values { continuation.yield() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.vinnysaj.vinnyfin.streaming.path"))
        return monitor
    }()
}
