import ImageIO
import Nuke
import NukeUI
import SwiftUI
import Synchronization

extension EnvironmentValues {
    /// Set inside the signed-in part of the app.
    @Entry var session: ServerSession?
}

/// An image from the server, cached in memory and on disk, filling a frame of a fixed shape.
/// One that didn't load because the server couldn't be reached, was too busy to send it, or sent
/// it cut short, is loaded again while it's on screen, waiting longer each time. While the server
/// is known to be out of reach, only a cached one shows, and the rest load as it answers.
struct Artwork: View {
    let url: URL?
    /// Nil fills whatever frame it's given.
    var aspectRatio: CGFloat? = 2.0 / 3.0
    var cornerRadius: CGFloat = 10
    /// The symbol on the gray card that stands in until the image is in, or for good when it
    /// can't load. Nil leaves the frame empty instead, for a picture that isn't a card.
    var placeholder: String? = "film"
    var contentMode = ContentMode.fill
    /// Where in the frame a picture that doesn't fill it sits.
    var alignment = Alignment.center
    /// What the picture says, for one that stands for words, as a title's logo stands for its
    /// name; nil hides a picture that's only decoration from VoiceOver.
    var label: String?

    var body: some View {
        Group {
            if let aspectRatio {
                Color.clear.aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: alignment) {
            ServerImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: contentMode)
                } else if let placeholder {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            if !state.isLoading {
                                Image(systemName: placeholder).font(.title2).foregroundStyle(.tertiary)
                            }
                        }
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        // Pictures keep their colors under Smart Invert.
        .accessibilityIgnoresInvertColors()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityAddTraits(label == nil ? [] : .isImage)
        .accessibilityHidden(label == nil)
    }

    /// Whether loading again might get the image that failed with `error`: the server couldn't be
    /// reached, answered that it's too busy or took too long, or sent the image cut short. It
    /// won't when the server says there's no such image, or sends one that isn't an image.
    nonisolated static func isWorthRetrying(_ error: any Error) -> Bool {
        switch error {
        case ImagePipeline.Error.dataLoadingFailed(let failure):
            switch failure {
            case DataLoader.Error.statusCodeUnacceptable(let status): return status == 408 || status == 429 || status >= 500
            case let failure as URLError: return failure.code != .cancelled
            default: return false
            }
        case ImagePipeline.Error.decodingFailed(_, _, let failure):
            return failure is IncompleteImage
        default:
            return false
        }
    }

    /// Whether `error` failed a load that wasn't sent for the server being out of reach, which
    /// is loaded again as it answers rather than on a timer.
    nonisolated static func waitsForServer(_ error: any Error) -> Bool {
        if case ImagePipeline.Error.dataLoadingFailed(let failure) = error { failure is ImageServerOutOfReach } else { false }
    }

    /// How long to wait before the `retry`th load again: a second, doubling each time up to half a
    /// minute.
    nonisolated static func delay(beforeRetry retry: Int) -> Duration {
        .seconds(min(pow(2, Double(retry - 1)), 30))
    }
}

/// An image from the server as `content` draws it in each state, loaded again after a failure
/// `Artwork.isWorthRetrying` finds worth it, waiting longer each time, while it's on screen. One
/// that wasn't in the caches while the server was out of reach is loaded again as it answers.
struct ServerImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (LazyImageState) -> Content
    /// Called as each load ends, but for one cut off by the view going away.
    var onCompletion: (Result<ImageResponse, any Error>) -> Void = { _ in }
    /// Nil where the app's screens don't set it, as in a widget or a test.
    @Environment(ServerReachability.self) private var reachability: ServerReachability?
    /// How many times the image has been loaded again since `url` was set.
    @State private var retries = 0
    /// How long to wait before loading it again, after a failure worth trying again.
    @State private var retryDelay: Duration?
    /// The last load wasn't sent, the server being out of reach, and is sent again as it answers.
    @State private var waitsForServer = false

    var body: some View {
        ZStack {
            LazyImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { state in
                content(state)
            }
            .onCompletion { result in
                let error: (any Error)? = if case .failure(let error) = result { error } else { nil }
                let wasntSent = error.map(Artwork.waitsForServer) ?? false
                // One that answered since, or that isn't followed here, goes on the timer.
                waitsForServer = wasntSent && reachability?.isOutOfReach == true
                let isWorthRetrying = error.map(Artwork.isWorthRetrying) == true || wasntSent && !waitsForServer
                retryDelay = isWorthRetrying ? Artwork.delay(beforeRetry: retries + 1) : nil
                if case ImagePipeline.Error.cancelled? = error { return }
                onCompletion(result)
            }
            .id(retries)
        }
        .onChange(of: reachability?.isOutOfReach) { _, isOutOfReach in
            guard isOutOfReach == false, waitsForServer else { return }
            waitsForServer = false
            retries += 1
        }
        .task(id: retryDelay) {
            guard let retryDelay else { return }
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                // Off screen; LazyImage loads it again when it's back.
                return
            }
            self.retryDelay = nil
            retries += 1
        }
        .onChange(of: url) {
            retries = 0
            retryDelay = nil
            waitsForServer = false
        }
    }
}

enum ImageCache {
    /// What loads the images the caches don't have, which `serverOutOfReach(_:)` keeps from the
    /// server while it can't be reached.
    private static var loader: ServerImageLoader?

    /// Takes the server at `server` to be out of reach, so only the images cached from it show;
    /// nil once it answers again.
    static func serverOutOfReach(_ server: URL?) {
        loader?.serverOutOfReach(server)
    }

    /// A disk cache for artwork, so lists come back instantly and scroll without refetching.
    static func configure() {
        var configuration = ImagePipeline.Configuration.withDataCache(name: "net.vinnysaj.vinnyfin.images", sizeLimit: 800 << 20)
        configuration.isProgressiveDecodingEnabled = false
        configuration.makeImageDecoder = { context in
            ImageDecoderRegistry.shared.decoder(for: context).map { CompleteImageDecoder(base: $0, request: context.request) }
        }
        let loader = ServerImageLoader(base: configuration.dataLoader)
        configuration.dataLoader = loader
        self.loader = loader
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }
}

/// The server images come from is out of reach: an image not in the caches isn't asked of it.
nonisolated struct ImageServerOutOfReach: Error {}

/// Loads images' data, but none from a server out of reach: there, a load fails at once with
/// `ImageServerOutOfReach`, so what the caches have shows and the rest stand in rather than wait
/// out the network's timeout. Loads from it under way as it goes out of reach are cut short, and
/// fail the same way.
nonisolated final class ServerImageLoader: DataLoading {
    private let base: any DataLoading

    private struct Load {
        let url: URL
        /// Nil until `base` has started it.
        var cancellable: (any Cancellable)?
        /// Cut short for the server going out of reach.
        var isCut = false
    }

    private struct State {
        /// The address of the server out of reach.
        var server: URL?
        var loads: [UUID: Load] = [:]
    }

    private let state = Mutex(State())

    init(base: any DataLoading) {
        self.base = base
    }

    /// Takes the server at `server` to be out of reach, cutting short what's loading from it; nil
    /// once it answers again.
    func serverOutOfReach(_ server: URL?) {
        let cut = state.withLock { (state: inout State) -> [any Cancellable] in
            state.server = server
            guard let server else { return [] }
            var cut: [any Cancellable] = []
            for (id, load) in state.loads where !load.isCut && Self.isOn(server, load.url) {
                state.loads[id]?.isCut = true
                if let cancellable = load.cancellable { cut.append(cancellable) }
            }
            return cut
        }
        cut.forEach { $0.cancel() }
    }

    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable ((any Error)?) -> Void) -> any Cancellable {
        guard let url = request.url else { return base.loadData(with: request, didReceiveData: didReceiveData, completion: completion) }
        let id = UUID()
        let isOutOfReach = state.withLock { (state: inout State) -> Bool in
            if let server = state.server, Self.isOn(server, url) { return true }
            state.loads[id] = Load(url: url)
            return false
        }
        guard !isOutOfReach else {
            completion(ImageServerOutOfReach())
            return Unstarted()
        }
        let cancellable = base.loadData(with: request, didReceiveData: didReceiveData) { [self] error in
            let wasCut = state.withLock { $0.loads.removeValue(forKey: id)?.isCut ?? false }
            completion(wasCut && error != nil ? ImageServerOutOfReach() : error)
        }
        // Cut short before `base` had started it: as soon as it has.
        let wasCut = state.withLock { (state: inout State) -> Bool in
            state.loads[id]?.cancellable = cancellable
            return state.loads[id]?.isCut ?? false
        }
        if wasCut { cancellable.cancel() }
        return cancellable
    }

    /// Whether `url` is on the server at `server`: the same scheme, host and port, under its path.
    static func isOn(_ server: URL, _ url: URL) -> Bool {
        guard url.scheme == server.scheme, url.host() == server.host(), url.port == server.port else { return false }
        let root = server.path().hasSuffix("/") ? String(server.path().dropLast()) : server.path()
        return root.isEmpty || url.path() == root || url.path().hasPrefix(root + "/")
    }

    private struct Unstarted: Cancellable {
        func cancel() {}
    }
}

/// The image's data stops short of its end, as a download cut off partway does.
nonisolated struct IncompleteImage: Error {}

/// Decodes only images whose data is whole. A cut-off download decodes as a picture missing its
/// lower part, and the disk cache would keep it, and show it, for good: here it fails instead,
/// as worth loading again, and its copy leaves the disk cache so the next load downloads it anew.
nonisolated struct CompleteImageDecoder: ImageDecoding {
    let base: any ImageDecoding
    let request: ImageRequest

    func decode(_ data: Data) throws -> ImageContainer {
        guard ImageData.isComplete(data) else {
            ImagePipeline.shared.cache.removeCachedData(for: request)
            throw IncompleteImage()
        }
        return try base.decode(data)
    }
}

/// What an image's bytes say about it.
nonisolated enum ImageData {
    /// Whether `data` holds a whole image: for PNG, JPEG, GIF and WebP, its format's last marker is
    /// there, or the length its header gives; for others, Image I/O finds it complete.
    static func isComplete(_ data: Data) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ends(data, with: Array("IEND".utf8))
        }
        if data.starts(with: [0xFF, 0xD8]) {
            return ends(data, with: [0xFF, 0xD9])
        }
        if data.starts(with: Array("GIF".utf8)) {
            return ends(data, with: [0x3B])
        }
        if data.count >= 12, data.starts(with: Array("RIFF".utf8)), data.dropFirst(8).starts(with: Array("WEBP".utf8)) {
            let length = data.dropFirst(4).prefix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
            return data.count >= length + 8
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetStatus(source) == .statusComplete
    }

    /// Whether `marker` is among the last bytes of `data`, where some writers leave a few bytes
    /// of padding after it.
    private static func ends(_ data: Data, with marker: [UInt8]) -> Bool {
        let tail = data.suffix(marker.count + 32)
        return tail.indices.contains { tail[$0...].starts(with: marker) }
    }
}
