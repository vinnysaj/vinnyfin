import CoreGraphics

/// Where what comes and goes over the picture sits around the controls, from the measured edges
/// of their bars: the up-next card and the skip button along the bottom, the track panels, and
/// what the title's picture says while it stands in for the video.
nonisolated enum PlayerLayout {
    /// From the top of the controls' bottom bar, while they show.
    static var gapAboveControls: CGFloat {
        #if os(tvOS)
        24
        #else
        16
        #endif
    }

    /// From the bottom of the screen, while the controls are hidden.
    static let gapAboveEdge: CGFloat = 40

    /// Below this, the band between the controls' bars can't hold the transport in its middle and
    /// the up-next card under it: about the transport's 70 points, with the card's 110 and its gap
    /// on each side of it. It's an iPhone on its side, or a short window.
    static let shortBand: CGFloat = 320

    /// How far up from the bottom of a view whose bottom is at `containerMaxY` (in global
    /// coordinates) something along the bottom sits: clear of the controls' bottom bar, which
    /// starts at `bottomBarTop` while they show, else `gapAboveEdge` up.
    static func bottomPadding(containerMaxY: CGFloat, bottomBarTop: CGFloat?) -> CGFloat {
        guard let bottomBarTop else { return gapAboveEdge }
        return max(0, containerMaxY - bottomBarTop) + gapAboveControls
    }

    /// The band between the controls' top bar, which ends at `topBarBottom`, and their bottom
    /// bar, which starts at `bottomBarTop`: whether it's too short for more than the transport.
    static func isShort(topBarBottom: CGFloat?, bottomBarTop: CGFloat?) -> Bool {
        guard let topBarBottom, let bottomBarTop else { return false }
        return bottomBarTop - topBarBottom < shortBand
    }

    enum UpNextForm: Equatable {
        /// The episode's still, its name, Play Now and Hide.
        case card
        /// A slim button just above the timeline, saying what's next.
        case pill
    }

    /// The card, except where the controls show and leave no room for it under the transport,
    /// which it would cover.
    static func upNextForm(controlsVisible: Bool, isShort: Bool) -> UpNextForm {
        controlsVisible && isShort ? .pill : .card
    }

    /// The up-next card's width on a screen `containerWidth` wide: a share of a wide screen, from
    /// the phone's 440 points to 640.
    static func upNextCardWidth(containerWidth: CGFloat) -> CGFloat {
        min(max(440, containerWidth * 0.4), 640)
    }

    /// The highest of the tops of what covers the bottom of the picture, in global coordinates,
    /// for subtitles to clear: nil when nothing does.
    static func coveredBelow(_ tops: CGFloat?...) -> CGFloat? {
        tops.compactMap(\.self).min()
    }
}
