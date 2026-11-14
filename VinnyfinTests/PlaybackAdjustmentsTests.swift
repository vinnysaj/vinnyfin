import AetherEngine
import Foundation
import Testing
@testable import vinnyfin

/// A defaults domain of its own, emptied after.
private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "PlaybackAdjustmentsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

struct SubtitleOffsetsTests {
    @Test func aTitlesTimingIsRememberedForIt() {
        withDefaults { defaults in
            SubtitleOffsets(defaults: defaults).set(0.3, for: "movie-a")
            SubtitleOffsets(defaults: defaults).set(-1.2, for: "movie-b")
            // Read back by another instance, as the next playback does.
            let offsets = SubtitleOffsets(defaults: defaults)
            #expect(offsets.offset(for: "movie-a") == 0.3)
            #expect(offsets.offset(for: "movie-b") == -1.2)
            #expect(offsets.offset(for: "movie-c") == 0)
        }
    }

    @Test func settingItAgainReplacesItAndZeroForgetsIt() {
        withDefaults { defaults in
            let offsets = SubtitleOffsets(defaults: defaults)
            offsets.set(0.5, for: "movie-a")
            offsets.set(0.7, for: "movie-a")
            #expect(offsets.offset(for: "movie-a") == 0.7)
            offsets.set(0, for: "movie-a")
            #expect(offsets.offset(for: "movie-a") == 0)
        }
    }

    @Test func onlyTheMostRecentlyTimedTitlesAreKept() {
        withDefaults { defaults in
            let offsets = SubtitleOffsets(defaults: defaults)
            for index in 0...SubtitleOffsets.capacity {
                offsets.set(0.1, for: "title-\(index)")
            }
            #expect(offsets.offset(for: "title-0") == 0)
            #expect(offsets.offset(for: "title-1") == 0.1)
            #expect(offsets.offset(for: "title-\(SubtitleOffsets.capacity)") == 0.1)
            // Setting an old one again makes it the most recent.
            offsets.set(0.2, for: "title-1")
            offsets.set(0.1, for: "title-new")
            #expect(offsets.offset(for: "title-1") == 0.2)
            #expect(offsets.offset(for: "title-2") == 0)
        }
    }

    @Test func stepsAddUpExactlyWithinTheLimit() {
        var offset = 0.0
        for _ in 0..<3 { offset = SubtitleOffsets.rounded(offset + SubtitleOffsets.step) }
        #expect(offset == 0.3)
        #expect(SubtitleOffsets.rounded(0.04) == 0)
        #expect(SubtitleOffsets.rounded(-0.06) == -0.1)
        #expect(SubtitleOffsets.rounded(500) == SubtitleOffsets.limit)
        #expect(SubtitleOffsets.rounded(-.infinity) == 0)
    }

    @Test func itReadsAsASignedNumberOfSeconds() {
        #expect(SubtitleOffsets.label(0.3) == "+0.3 s")
        #expect(SubtitleOffsets.label(-1.2) == "\u{2212}1.2 s")
        #expect(SubtitleOffsets.label(0) == "0.0 s")
        #expect(SubtitleOffsets.spoken(0) == "In time")
        #expect(SubtitleOffsets.spoken(0.3) == "0.3 seconds later")
        #expect(SubtitleOffsets.spoken(-1.2) == "1.2 seconds earlier")
    }
}

struct SoundOptionsTests {
    @Test func offShapesNothing() {
        #expect(SoundOptions().shaping == AudioShaping())
    }

    @Test func eachToolShapesTheSoundItsWay() {
        var sound = SoundOptions()
        sound.boostsDialogue = true
        #expect(sound.shaping == AudioShaping(dialogueGainDB: SoundOptions.dialogueBoost))
        sound.reducesLoudSounds = true
        #expect(sound.shaping == AudioShaping(dialogueGainDB: SoundOptions.dialogueBoost, compressor: .night))
        sound.boostsDialogue = false
        #expect(sound.shaping == AudioShaping(compressor: .night))
        #expect(SoundOptions.dialogueBoost <= AudioShaping.maxDialogueGainDB)
    }

    @Test func theChoiceIsKeptForTheNextPlayback() {
        withDefaults { defaults in
            #expect(SoundOptions.saved(in: defaults) == SoundOptions())
            var sound = SoundOptions()
            sound.reducesLoudSounds = true
            sound.save(in: defaults)
            #expect(SoundOptions.saved(in: defaults) == sound)
        }
    }
}

struct PlayerVolumeTests {
    @Test func theKeysStepTheVolumeWithinRange() {
        var volume = PlayerVolume(level: 1)
        volume.change(up: true)
        #expect(volume.level == 1)
        volume.change(up: false)
        #expect(volume.level == 1 - PlayerVolume.step)
        var quiet = PlayerVolume(level: PlayerVolume.step)
        quiet.change(up: false)
        quiet.change(up: false)
        #expect(quiet.level == 0)
        // A level between steps lands on one.
        var between = PlayerVolume(level: 0.52)
        between.change(up: true)
        #expect(between.level == 9 * PlayerVolume.step)
    }

    @Test func mutingSilencesAndAStepUnmutes() {
        var volume = PlayerVolume(level: 0.5)
        volume.toggleMute()
        #expect(volume.isMuted)
        #expect(volume.output == 0)
        #expect(volume.level == 0.5)
        volume.change(up: false)
        #expect(!volume.isMuted)
        #expect(volume.output == 0.5 - PlayerVolume.step)
    }
}

@MainActor
struct PlaybackSpeedTests {
    @Test func aSpeedAskedForElsewhereLandsOnTheNearestChoice() {
        #expect(PlaybackSpeed.nearest(to: 1.1) == 1)
        #expect(PlaybackSpeed.nearest(to: 1.4) == 1.5)
        #expect(PlaybackSpeed.nearest(to: 3) == 2)
        #expect(PlaybackSpeed.nearest(to: 0.1) == 0.5)
    }
}
