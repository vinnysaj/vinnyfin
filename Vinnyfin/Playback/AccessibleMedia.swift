import Foundation
import MediaAccessibility

/// What the system's Accessibility settings ask of video: Subtitles & Captioning's Closed
/// Captions + SDH, and Audio Descriptions. Read as a playback picks its tracks, so a change
/// applies from the next one.
nonisolated enum AccessibleMedia {
    /// Closed Captions + SDH is on: subtitles show whatever the subtitle setting says, closed
    /// captions (SDH) first.
    static var prefersCaptions: Bool {
        MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
    }

    /// A caption style other than the system's default is chosen, which subtitles take.
    static var hasCaptionStyle: Bool {
        MACaptionAppearanceIsCustomized(.user)
    }

    /// Audio Descriptions is on: a title plays its described audio when it has some.
    static var prefersAudioDescriptions: Bool {
        let preferred = MAAudibleMediaCopyPreferredCharacteristics().takeRetainedValue() as? [String] ?? []
        return preferred.contains(MAMediaCharacteristicDescribesVideoForAccessibility as String)
    }

    /// Posted when either setting changes. On the Mac it's changed in System Settings, another
    /// process, which posts it to the distributed center.
    static let captionsChanged = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)
    static let audioDescriptionsChanged = Notification.Name(kMAAudibleMediaSettingsChangedNotification as String)

    /// Whether a track's title calls it an audio description: the narration of what's on screen
    /// for blind and low-vision viewers, which files mark with a flag only now and then, and
    /// Jellyfin never. English titles say "Audio Description", "Descriptive Audio", "Described
    /// Video" or "DVS", or carry "AD" as a word; other languages run the words together.
    static func namesAudioDescription(_ title: String?) -> Bool {
        guard let title = title?.lowercased(), !title.isEmpty else { return false }
        let phrases = ["audio description", "audio-description", "audio described", "descriptive audio", "descriptive video",
                       "described video", "video description", "audiodescri", "audiodeskription", "audiobeschrijving",
                       "synstolk", "kuvailutulkkaus"]
        if phrases.contains(where: title.contains) { return true }
        let words = title.split { !$0.isLetter }
        return words.contains("ad") || words.contains("dvs")
    }
}

nonisolated extension MediaStream {
    /// An audio stream whose title calls it an audio description. Jellyfin has no flag for one.
    var isAudioDescription: Bool {
        type == "Audio" && (AccessibleMedia.namesAudioDescription(title) || AccessibleMedia.namesAudioDescription(displayTitle))
    }
}
