#if os(macOS)
import SwiftUI
import WebKit

/// YouTube's website filling Portable TV's screen, with the pointer the remote moves over it.
struct TVYouTubeView: View {
    let youTube: YouTubeTV
    @Environment(\.tvScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            WebViewHost(webView: youTube.webView)
                .overlay(alignment: .topLeading) {
                    if let pointer = youTube.pointer {
                        Circle()
                            .fill(.white.opacity(0.85))
                            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
                            .frame(width: 30 * scale, height: 30 * scale)
                            .shadow(color: .black.opacity(0.5), radius: 6)
                            .position(x: pointer.x * geometry.size.width, y: pointer.y * geometry.size.height)
                            .animation(.linear(duration: 0.1), value: pointer)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: youTube.pointer == nil)
                .onChange(of: geometry.size.width, initial: true) { _, width in youTube.fit(width: width) }
        }
        .onAppear { youTube.show() }
    }
}

/// Holds the one web view, which moves into each new host as the view is drawn again, keeping
/// its page.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        place(in: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        if webView.superview !== host { place(in: host) }
    }

    private func place(in host: NSView) {
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
        // Once in a window, the page takes the keyboard, for the Mac's keys and the remote's.
        DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
    }
}
#endif
