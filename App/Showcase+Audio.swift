// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Editing
import Foundation
import ProjectFormat

extension EditorModel {
    /// The showcase of the sound, a track per app, the ranges, the J and L cuts, the music and its ducking (3c): what its
    /// `TOMA_SHOWCASE_P3_*` variables ask for.
    ///
    /// `TOMA_SHOWCASE_P3_AUDIO=rows` (U11): the take cut in two clips (if it is one), a stretch at −6 dB on the microphone
    /// from 1 s to 3 s, a J cut of −0,3 s at the second clip, Solo on the microphone and the stretch selected.
    func showcaseAudio(_ environment: [String: String]) async {
        if environment["TOMA_SHOWCASE_P3_AUDIO"] == "rows" { showcaseAudioRows() }
    }

    private func showcaseAudioRows() {
        guard let document, let microphone = audioTracks.first(where: \.isMicrophone) ?? audioTracks.first else { return }
        let duration = TimeMap(sequence: document.sequence).duration
        if document.sequence.count == 1, let step = SequenceCommands.split(document, atOutput: duration / 2, makeID: Self.newID) {
            perform(step)
        }
        addGainRange(track: microphone.track, forOutput: 1_000_000_000..<3_000_000_000, gain: -6)
        let selected = selection
        setAudioShift(clip: 1, to: -300_000_000)
        toggleSolo(.track(microphone.track))
        selection = selected
    }
}
#endif
