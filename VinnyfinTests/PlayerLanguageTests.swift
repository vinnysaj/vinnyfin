import AVFoundation
import Foundation
import Testing
@testable import vinnyfin

private func track(_ id: Int, _ language: String?, forced: Bool = false, captions: Bool = false, name: String? = nil,
                   describesVideo: Bool = false) -> TrackChooser.Candidate {
    TrackChooser.Candidate(id: id, language: language, isForced: forced, isHearingImpaired: captions, isDefault: false,
                           name: name, describesVideo: describesVideo)
}

struct NowPlayingLanguagesTests {
    @Test func writesAFilesLanguageAsTheSystemTakesIt() {
        #expect(NowPlayingLanguages.languageTag("eng") == "en")
        #expect(NowPlayingLanguages.languageTag("fre") == "fr")
        #expect(NowPlayingLanguages.languageTag("ger") == "de")
        #expect(NowPlayingLanguages.languageTag("chi") == "zh")
        #expect(NowPlayingLanguages.languageTag("jpn") == "ja")
        #expect(NowPlayingLanguages.languageTag("pt-BR") == "pt-BR")
        #expect(NowPlayingLanguages.languageTag("en") == "en")
        #expect(NowPlayingLanguages.languageTag(nil) == "und")
        #expect(NowPlayingLanguages.languageTag("und") == "und")
    }

    @Test func describesCaptionsForcedSubtitlesAndAudioDescriptions() {
        let captions = NowPlayingLanguages.option(.subtitles, track(3, "eng", captions: true), title: "English · SDH")
        #expect(captions.characteristics.contains(AVMediaCharacteristic.transcribesSpokenDialogForAccessibility.rawValue))
        #expect(captions.characteristics.contains(AVMediaCharacteristic.describesMusicAndSoundForAccessibility.rawValue))
        let forced = NowPlayingLanguages.option(.subtitles, track(4, "eng", forced: true), title: "English · Forced")
        #expect(forced.characteristics == [AVMediaCharacteristic.containsOnlyForcedSubtitles.rawValue])
        let described = NowPlayingLanguages.option(.audio, track(1, "eng", describesVideo: true), title: "English · Audio Description")
        #expect(described.characteristics == [AVMediaCharacteristic.describesVideoForAccessibility.rawValue])
        let plain = NowPlayingLanguages.option(.subtitles, track(5, "fre"), title: "French")
        #expect(plain.characteristics.isEmpty)
        #expect(plain.languageTag == "fr")
        #expect(plain.displayName == "French")
    }

    @Test func anOptionsIdentifierNamesItsTrack() {
        let option = NowPlayingLanguages.option(.subtitles, track(12, "eng"), title: "English")
        #expect(NowPlayingLanguages.track(named: option.identifier)?.kind == .subtitles)
        #expect(NowPlayingLanguages.track(named: option.identifier)?.trackId == 12)
        #expect(NowPlayingLanguages.track(named: "audio.2")?.kind == .audio)
        #expect(NowPlayingLanguages.track(named: "something") == nil)
    }

    private var subtitles: [NowPlayingLanguages.Option] {
        [
            NowPlayingLanguages.option(.subtitles, track(3, "eng", forced: true), title: "English · Forced"),
            NowPlayingLanguages.option(.subtitles, track(4, "eng"), title: "English"),
            NowPlayingLanguages.option(.subtitles, track(5, "eng", captions: true), title: "English · SDH"),
            NowPlayingLanguages.option(.subtitles, track(6, "fre"), title: "French"),
        ]
    }

    @Test func aCommandGetsTheTrackItsOptionNames() {
        #expect(NowPlayingLanguages.trackId(askedFor: "subtitles.6", kind: .subtitles, languageTag: "fr", characteristics: [],
                                            among: subtitles) == 6)
        // A name for a track that isn't there goes by the language instead.
        #expect(NowPlayingLanguages.trackId(askedFor: "subtitles.99", kind: .subtitles, languageTag: "fr", characteristics: [],
                                            among: subtitles) == 6)
    }

    @Test func turnOnFrenchSubtitlesFindsThemByLanguage() {
        #expect(NowPlayingLanguages.trackId(askedFor: nil, kind: .subtitles, languageTag: "fr", characteristics: [],
                                            among: subtitles) == 6)
        // English: the full subtitles, not the forced ones listed first.
        #expect(NowPlayingLanguages.trackId(askedFor: nil, kind: .subtitles, languageTag: "en", characteristics: [],
                                            among: subtitles) == 4)
        #expect(NowPlayingLanguages.trackId(askedFor: nil, kind: .subtitles, languageTag: "de", characteristics: [],
                                            among: subtitles) == nil)
    }

    @Test func turnOnClosedCaptionsFindsTheCaptions() {
        let captions = [AVMediaCharacteristic.transcribesSpokenDialogForAccessibility.rawValue,
                        AVMediaCharacteristic.describesMusicAndSoundForAccessibility.rawValue]
        #expect(NowPlayingLanguages.trackId(askedFor: nil, kind: .subtitles, languageTag: "en", characteristics: captions,
                                            among: subtitles) == 5)
        // With no captions in the language, full subtitles.
        #expect(NowPlayingLanguages.trackId(askedFor: nil, kind: .subtitles, languageTag: "fr", characteristics: captions,
                                            among: subtitles) == 6)
    }

    @Test func anAudioCommandDoesntPickSubtitles() {
        #expect(NowPlayingLanguages.trackId(askedFor: "subtitles.6", kind: .audio, languageTag: "fr", characteristics: [],
                                            among: subtitles) == nil)
    }
}

struct ReplaySubtitlesTests {
    private let tracks = [
        track(3, "eng", forced: true),
        track(4, "eng"),
        track(5, "eng", captions: true),
        track(6, "fre"),
        track(7, "jpn"),
    ]

    @Test func withSubtitlesOffASkipBackShowsTheSubtitleLanguages() {
        #expect(ReplaySubtitles.track(in: tracks, showing: nil, language: "eng", audioLanguage: "jpn", captions: false) == 4)
        #expect(ReplaySubtitles.track(in: tracks, showing: nil, language: "fre", audioLanguage: "eng", captions: false) == 6)
    }

    @Test func forcedSubtitlesGiveWayToFullOnesInTheirLanguage() {
        #expect(ReplaySubtitles.track(in: tracks, showing: 3, language: "fre", audioLanguage: "eng", captions: false) == 4)
    }

    @Test func fullSubtitlesShowingAlreadyChangeNothing() {
        #expect(ReplaySubtitles.track(in: tracks, showing: 6, language: "eng", audioLanguage: "eng", captions: false) == nil)
    }

    @Test func withClosedCaptionsOnCaptionsComeFirst() {
        #expect(ReplaySubtitles.track(in: tracks, showing: nil, language: "eng", audioLanguage: "eng", captions: true) == 5)
    }

    @Test func noSubtitleLanguageFallsBackOnTheAudios() {
        #expect(ReplaySubtitles.track(in: tracks, showing: nil, language: "", audioLanguage: "jpn", captions: false) == 7)
        #expect(ReplaySubtitles.track(in: tracks, showing: nil, language: "ger", audioLanguage: "ita", captions: false) == nil)
        #expect(ReplaySubtitles.track(in: [track(3, "eng", forced: true)], showing: nil, language: "eng", audioLanguage: "eng",
                                      captions: false) == nil)
    }

    @Test func theSubtitlesGoOnceThePlayheadIsBackWhereItWas() {
        var replay = ReplaySubtitles(until: 100, before: nil, shown: 4)
        // Before the skip back lands, the playhead still reads where it skipped from.
        let ends = [100.2, 90, 99.5, 100.1].map { replay.playhead(at: $0) }
        #expect(ends == [false, false, false, true])
    }

    @Test func aRunOfSkipsBackShowsThemUntilBackWhereTheFirstBegan() {
        var replay = ReplaySubtitles(until: 100, before: 3, shown: 4)
        let first = replay.playhead(at: 91)
        replay.skippedBack(from: 91)
        #expect(replay.until == 100)
        let ends = [85, 99, 100].map { replay.playhead(at: $0) }
        #expect(!first)
        #expect(ends == [false, false, true])
        #expect(replay.before == 3)
    }
}
