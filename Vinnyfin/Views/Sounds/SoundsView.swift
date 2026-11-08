import SwiftUI

/// Sounds: picks the sound to play, plays, pauses and stops it, and sets the sleep timer. A sheet
/// from Home, and a tab of its own on Apple TV.
struct SoundsView: View {
    @Environment(SoundPlayer.self) private var sounds
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Sound.allCases) { sound in
                        Button { choose(sound) } label: { SoundRow(sound: sound) }
                            .accessibilityIdentifier("sounds.\(sound.rawValue)")
                    }
                } footer: {
                    Text("Made on this \(Device.name) as they play, so they never loop. They keep playing with the screen locked, and pause for a video.")
                }
                controls
                sleepTimer
                if let problem = sounds.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Dismiss") { sounds.problem = nil }
                    }
                }
            }
            .formStyle(.grouped)
            .screenTitle("Sounds")
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 620)
        #endif
    }

    @ViewBuilder private var controls: some View {
        Section {
            if sounds.state == .playing {
                Button("Pause", systemImage: "pause.fill") { sounds.pause() }
                    .accessibilityIdentifier("sounds.pause")
            } else {
                Button("Play", systemImage: "play.fill") { sounds.play() }
                    .accessibilityIdentifier("sounds.play")
            }
            if sounds.state != .stopped {
                Button("Stop", systemImage: "stop.fill") { sounds.stop() }
                    .accessibilityIdentifier("sounds.stop")
            }
        } footer: {
            if sounds.isSteppedAside, sounds.state == .playing {
                Text("Waiting while a video plays. It carries on once the video closes.")
            }
        }
    }

    @ViewBuilder private var sleepTimer: some View {
        Section {
            SettingPicker("Sleep Timer", selection: Binding(get: { sounds.timer }, set: { sounds.setTimer($0) })) {
                ForEach(timerChoices) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("sounds.sleepTimer")
            if let deadline = sounds.deadline {
                LabeledContent("Stops In") {
                    Text(deadline, style: .timer).monospacedDigit()
                }
                .accessibilityIdentifier("sounds.stopsIn")
            }
        } footer: {
            #if os(tvOS)
            Text("Fades out and stops after the time you choose.")
            #else
            Text("Fades out and stops after the time you choose, or once your downloads finish.")
            #endif
        }
    }

    /// When Downloads Finish only while downloads are under way, or while it's chosen.
    private var timerChoices: [SleepTimer] {
        #if os(tvOS)
        SleepTimer.choices
        #else
        let hasDownloads = !DownloadJob.queue(downloads.jobs).isEmpty
        return SleepTimer.choices.filter { $0 != .whenDownloadsFinish || hasDownloads || sounds.timer == .whenDownloadsFinish }
        #endif
    }

    /// The sound playing pauses; any other plays.
    private func choose(_ sound: Sound) {
        if sound == sounds.sound, sounds.state == .playing {
            sounds.pause()
        } else {
            sounds.play(sound)
        }
    }
}

/// A sound, marked when it's the one chosen: moving while it plays.
private struct SoundRow: View {
    let sound: Sound
    @Environment(SoundPlayer.self) private var sounds

    private var isChosen: Bool { sound == sounds.sound }
    private var isPlaying: Bool { isChosen && sounds.state == .playing && !sounds.isSteppedAside }

    var body: some View {
        HStack {
            Label {
                // In a button the primary style is the tint, so the name takes the label color
                // itself, reading as a choice rather than a link. Apple TV's focus colors it.
                #if os(tvOS)
                Text(sound.name)
                #else
                Text(sound.name).foregroundStyle(Color.primary)
                #endif
            } icon: {
                Image(systemName: sound.systemImage)
            }
            Spacer()
            if isChosen, sounds.state != .stopped {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            } else if isChosen {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isPlaying ? "Playing" : isChosen && sounds.state == .paused ? "Paused" : "")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
