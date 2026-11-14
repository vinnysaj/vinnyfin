import ImageIO
import Nuke
import NukeUI
import SwiftUI

extension EnvironmentValues {
    /// Set inside the signed-in part of the app.
    @Entry var session: ServerSession?
}

/// An image from the server, cached in memory and on disk, filling a frame of a fixed shape.
/// One that didn't load because the server couldn't be reached, was too busy to send it, or sent
/// it cut short, is loaded again while it's on screen, waiting longer each time.
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

    /// How long to wait before the `retry`th load again: a second, doubling each time up to half a
    /// minute.
    nonisolated static func delay(beforeRetry retry: Int) -> Duration {
        .seconds(min(pow(2, Double(retry - 1)), 30))
    }
}

/// An image from the server as `content` draws it in each state, loaded again after a failure
/// `Artwork.isWorthRetrying` finds worth it, waiting longer each time, while it's on screen.
struct ServerImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (LazyImageState) -> Content
    /// Called as each load ends, but for one cut off by the view going away.
    var onCompletion: (Result<ImageResponse, any Error>) -> Void = { _ in }
    /// How many times the image has been loaded again since `url` was set.
    @State private var retries = 0
    /// How long to wait before loading it again, after a failure worth trying again.
    @State private var retryDelay: Duration?

    var body: some View {
        ZStack {
            LazyImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { state in
                content(state)
            }
            .onCompletion { result in
                if case .failure(let error) = result, Artwork.isWorthRetrying(error) {
                    retryDelay = Artwork.delay(beforeRetry: retries + 1)
                } else {
                    retryDelay = nil
                }
                if case .failure(ImagePipeline.Error.cancelled) = result { return }
                onCompletion(result)
            }
            .id(retries)
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
        }
    }
}

enum ImageCache {
    /// A disk cache for artwork, so lists come back instantly and scroll without refetching.
    static func configure() {
        var configuration = ImagePipeline.Configuration.withDataCache(name: "net.vinnysaj.vinnyfin.images", sizeLimit: 800 << 20)
        configuration.isProgressiveDecodingEnabled = false
        configuration.makeImageDecoder = { context in
            ImageDecoderRegistry.shared.decoder(for: context).map { CompleteImageDecoder(base: $0, request: context.request) }
        }
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
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
