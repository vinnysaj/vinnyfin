import AVFoundation
import Foundation
import MediaPlayer

/// The audio tracks and subtitles of a playback as the system's Now Playing lists them, for Siri
/// ("Turn on French subtitles", "Turn on closed captions") and for the remotes that offer them,
/// and the way back from the option a command names to the track.
nonisolated enum NowPlayingLanguages {
    enum Kind: Equatable {
        case audio, subtitles
    }

    /// One audio track or subtitle track, as Now Playing describes it.
    struct Option: Equatable {
        let kind: Kind
        /// The track's id among the player's choices (`TrackOption.id`).
        let trackId: Int
        /// The language as BCP 47, as Now Playing takes it: "en", "pt-BR"; "und" when unknown.
        let languageTag: String
        /// `AVMediaCharacteristic`s: forced subtitles, captions, an audio description.
        let characteristics: [String]
        let displayName: String

        /// What names the option in a command, and the track it is.
        var identifier: String { "\(kind == .audio ? "audio" : "subtitles").\(trackId)" }
    }

    /// The option for `candidate`, a track called `title` in the player's menus.
    static func option(_ kind: Kind, _ candidate: TrackChooser.Candidate, title: String) -> Option {
        var characteristics: [AVMediaCharacteristic] = []
        switch kind {
        case .audio:
            if candidate.describesVideo { characteristics.append(.describesVideoForAccessibility) }
        case .subtitles:
            if candidate.showsOnlyForced {
                characteristics.append(.containsOnlyForcedSubtitles)
            } else if candidate.isCaptions {
                characteristics += [.transcribesSpokenDialogForAccessibility, .describesMusicAndSoundForAccessibility]
            }
        }
        return Option(kind: kind, trackId: candidate.id, languageTag: languageTag(candidate.language),
                      characteristics: characteristics.map(\.rawValue), displayName: title)
    }

    /// The track an option's `identifier` names.
    static func track(named identifier: String) -> (kind: Kind, trackId: Int)? {
        let parts = identifier.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let id = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "audio": return (.audio, id)
        case "subtitles": return (.subtitles, id)
        default: return nil
        }
    }

    /// The track a command asks for with an option of `kind`: the one it names, else among
    /// `options` the first in its language, of the kind of subtitles its characteristics ask for
    /// (captions, forced) when they ask for one, full ones before forced ones otherwise.
    static func trackId(askedFor identifier: String?, kind: Kind, languageTag: String, characteristics: [String],
                        among options: [Option]) -> Int? {
        let ofKind = options.filter { $0.kind == kind }
        if let identifier, let named = track(named: identifier), named.kind == kind,
           ofKind.contains(where: { $0.trackId == named.trackId }) {
            return named.trackId
        }
        let inLanguage = ofKind.filter { AppSettings.sameLanguage($0.languageTag, languageTag) }
        let forced = AVMediaCharacteristic.containsOnlyForcedSubtitles.rawValue
        let captions = AVMediaCharacteristic.transcribesSpokenDialogForAccessibility.rawValue
        let full = inLanguage.first { !$0.characteristics.contains(forced) }
        let wanted = characteristics.filter { $0 == forced || $0 == captions }
        guard !wanted.isEmpty else { return (full ?? inLanguage.first)?.trackId }
        return (inLanguage.first { option in wanted.allSatisfy(option.characteristics.contains) } ?? full)?.trackId
    }

    /// BCP 47 for a file's language, which is ISO 639-2 more often than not: "eng" is "en",
    /// and "fre", the bibliographic code, "fr". A tag already short, or with a region, is kept.
    static func languageTag(_ code: String?) -> String {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty, code.lowercased() != "und" else { return "und" }
        guard code.count == 3, !code.contains("-") else { return code }
        let terminology = bibliographic[code.lowercased()] ?? code.lowercased()
        return Locale.LanguageCode(terminology).identifier(.alpha2) ?? terminology
    }

    /// ISO 639-2's bibliographic codes, which files use, to the terminology codes the system knows.
    private static let bibliographic = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
        "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
        "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    /// The system's form of `option`.
    static func mediaPlayerOption(_ option: Option) -> MPNowPlayingInfoLanguageOption {
        MPNowPlayingInfoLanguageOption(type: option.kind == .audio ? .audible : .legible, languageTag: option.languageTag,
                                       characteristics: option.characteristics, displayName: option.displayName,
                                       identifier: option.identifier)
    }
}
