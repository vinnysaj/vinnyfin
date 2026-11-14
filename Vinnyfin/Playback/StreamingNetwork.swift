import Foundation
import Network

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
        #if !os(tvOS)
        _ = monitor
        #endif
    }

    #if !os(tvOS)
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "net.vinnysaj.vinnyfin.streaming.path"))
        return monitor
    }()
    #endif
}
