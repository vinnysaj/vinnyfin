import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The speeds the player offers, and how it writes one.
enum PlaybackSpeed {
    static let choices: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// "1.5×".
    static func label(_ rate: Float) -> String {
        "\(rate.formatted())×"
    }

    /// What VoiceOver calls it, "Normal" at 1×.
    static func name(_ rate: Float) -> String {
        rate == 1 ? "Normal" : label(rate)
    }

    /// The choice nearest `rate`, as a remote can ask for any speed.
    static func nearest(to rate: Float) -> Float {
        choices.min { abs($0 - rate) < abs($1 - rate) } ?? 1
    }
}

/// Every speed in one row, in reach in any orientation, the speed playing lit. They keep their
/// size past the default text size, as the player's buttons do, and the Large Content Viewer
/// shows each one large.
struct SpeedChips: View {
    let model: PlayerModel
    /// Called once a speed is picked.
    let onChoose: () -> Void
    #if os(tvOS)
    /// The remote's place in the panel the chips are in, as `SpeedChips.focusID(_:)`.
    var focus: FocusState<String?>.Binding
    #endif

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(PlaybackSpeed.choices, id: \.self) { rate in
                chip(rate)
            }
        }
        #if os(tvOS)
        // Room for the dot under the speed playing.
        .padding(.bottom, 18)
        #endif
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// The chip for `rate`, for the remote to start on.
    static func focusID(_ rate: Float) -> String { "speed.\(rate)" }

    private func chip(_ rate: Float) -> some View {
        let isSelected = model.rate == rate
        return Button {
            model.setRate(rate)
            #if os(iOS)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
            onChoose()
        } label: {
            Text(PlaybackSpeed.label(rate))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: Self.minWidth)
        }
        .buttonStyle(SpeedChipStyle(isSelected: isSelected))
        #if os(tvOS)
        .focused(focus, equals: Self.focusID(rate))
        #endif
        .accessibilityLabel(PlaybackSpeed.name(rate))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("panel.\(Self.focusID(rate))")
    }

    private static var spacing: CGFloat {
        #if os(tvOS)
        20
        #else
        4
        #endif
    }

    private static var minWidth: CGFloat {
        #if os(tvOS)
        48
        #else
        20
        #endif
    }
}

/// A speed's chip, lit when it's the speed, like a season's chip on a show's page but closer cut,
/// so every speed fits across a phone held upright. A finger's height to tap, though drawn shorter.
/// On Apple TV it's glass, white glass being focus's alone as on a season's chip, and the speed
/// playing is in bold over a dot. The subtitles' timing steps are chips too.
struct SpeedChipStyle: ButtonStyle {
    let isSelected: Bool
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        configuration.label
            .font(.subheadline.weight(isSelected ? .bold : .semibold))
            .monospacedDigit()
            .padding(.horizontal, Self.padding)
            .padding(.vertical, 8)
            .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            .glassEffect(isFocused ? .focused : .regular, in: .capsule)
            .overlay(alignment: .bottom) {
                if isSelected {
                    // White, not the chip's title color, which goes dark on its glass under focus;
                    // nor `Color.primary`, which on the panel's glass comes out a dim gray.
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        // Under the chip, clear of it as focus lifts it: an alignment guide here
                        // goes unheeded, and the dot sits on the chip's edge, under its glass.
                        .offset(y: 18)
                }
            }
            // With Reduce Motion, focus lifts it with its shadow alone.
            .scaleEffect(isFocused && !reduceMotion ? 1.12 : 1)
            .shadow(radius: isFocused ? 12 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .opacity(configuration.isPressed ? 0.7 : 1)
        #else
        configuration.label
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, Self.padding)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.quaternary), in: .capsule)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.7 : 1)
        #endif
    }

    private static var padding: CGFloat {
        #if os(tvOS)
        18
        #else
        8
        #endif
    }
}
