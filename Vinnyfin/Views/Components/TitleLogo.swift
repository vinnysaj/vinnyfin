import Nuke
import NukeUI
import SwiftUI

/// A title's name over its hero: its logo, at the bottom leading corner of a box of a set height,
/// so it lines up with the facts and buttons under it and a hero full of buttons can't squeeze
/// it. Nothing shows in the box while the logo loads, and it fades in when it's there. Without a
/// logo, or while it can't load, the name shows in large bold type instead.
///
/// Put it under `.environment(\.colorScheme, .dark)`, as the heroes do, so the name reads on the
/// dark fade behind it. As a link, a chevron after the logo or name says it leads on.
struct TitleLogo: View {
    let url: URL?
    let name: String
    var leadsOn = false

    /// The width logos are asked for at, the same everywhere, so a logo seen on Home is already
    /// there, at the size wanted, on the title's page.
    static var requestWidth: Int {
        #if os(tvOS)
        1240
        #else
        900
        #endif
    }

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The logo that didn't load; the name stands in until a load of it again does.
    @State private var failedURL: URL?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url {
                ServerImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit()
                            // Keeps a light logo apart from a light picture behind it.
                            .shadow(color: .black.opacity(0.35), radius: 10)
                            // Just past the logo however wide it is, out of its box.
                            .overlay(alignment: .trailing) {
                                if leadsOn { chevron.alignmentGuide(.trailing) { $0[.leading] - 8 } }
                            }
                    }
                } onCompletion: { result in
                    let failed: URL? = if case .failure = result { url } else { nil }
                    if failed != failedURL { withAnimation(.easeOut(duration: 0.2)) { failedURL = failed } }
                }
                // Still loading again, out of sight, while the name stands in.
                .frame(maxWidth: size.width, maxHeight: showsName ? 0 : size.height, alignment: .bottomLeading)
            }
            if showsName {
                Text(leadsOn ? "\(name) \(Image(systemName: "chevron.right"))" : "\(name)")
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(dynamicTypeSize.lineLimit(3))
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: showsName ? nil : size.width, alignment: .leading)
        .frame(height: showsName ? nil : size.height, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .onChange(of: url) { failedURL = nil }
    }

    private var showsName: Bool { url == nil || failedURL == url }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.secondary)
            .shadow(color: .black.opacity(0.35), radius: 6)
    }

    /// The box the logo fits in. Held sideways, a phone keeps the hero short, and the logo with it.
    private var size: CGSize {
        #if os(tvOS)
        CGSize(width: 620, height: 200)
        #elseif os(iOS)
        CGSize(width: 320, height: verticalSizeClass == .compact ? 70 : 110)
        #else
        CGSize(width: 320, height: 110)
        #endif
    }
}
