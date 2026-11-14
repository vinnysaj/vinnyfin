import SwiftUI

/// The app's icon, drawn as `AppIcon.icon` composes it: a white V on the green to blue
/// gradient. Icon Composer's icons can't be loaded as an image, so it's drawn from the same
/// colors and shape.
struct AppMark: View {
    var size: CGFloat

    static let green = Color(.displayP3, red: 0.47381, green: 0.69075, blue: 0.46049)
    static let blue = Color(.displayP3, red: 0.38650, green: 0.62759, blue: 0.78775)

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Self.green, Self.blue], startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1)))
            .overlay {
                // The light the icon's glass catches along its top.
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .center),
                                  lineWidth: max(1, size / 90))
            }
            .overlay {
                Glyph()
                    .fill(.white)
                    .overlay { Glyph().stroke(.white, style: StrokeStyle(lineWidth: size * 92 / 1024, lineJoin: .round)) }
                    // One shadow for the whole V: the stroke's own would fall on its fill.
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.18), radius: size / 40, y: size / 80)
            }
            .frame(width: size, height: size)
            .shadow(color: Self.blue.opacity(0.35), radius: size / 8, y: size / 20)
            .accessibilityHidden(true)
    }

    /// The V, a triangle in the icon's 1024-point square.
    private nonisolated struct Glyph: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = rect.width / 1024
            var path = Path()
            path.move(to: CGPoint(x: 312 * scale, y: 322 * scale))
            path.addLine(to: CGPoint(x: 712 * scale, y: 322 * scale))
            path.addLine(to: CGPoint(x: 512 * scale, y: 742 * scale))
            path.closeSubpath()
            return path
        }
    }
}

/// The icon's green and blue, drifting slowly behind the screen before sign-in, and holding
/// still under Reduce Motion.
struct WelcomeBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var drifted = false

    var body: some View {
        GeometryReader { screen in
            let side = max(screen.size.width, screen.size.height)
            ZStack {
                Circle()
                    .fill(AppMark.green)
                    .frame(width: side * 0.8)
                    .offset(x: side * (drifted ? -0.22 : -0.32), y: side * (drifted ? -0.30 : -0.18))
                Circle()
                    .fill(AppMark.blue)
                    .frame(width: side * 0.9)
                    .offset(x: side * (drifted ? 0.30 : 0.20), y: side * (drifted ? 0.22 : 0.34))
            }
            .frame(width: screen.size.width, height: screen.size.height)
            .blur(radius: side * 0.18)
            .opacity(colorScheme == .dark ? 0.32 : 0.22)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) { drifted = true }
        }
        .onChange(of: reduceMotion) { _, reduce in
            withAnimation(reduce ? .default : .easeInOut(duration: 24).repeatForever(autoreverses: true)) { drifted = !reduce }
        }
    }
}
