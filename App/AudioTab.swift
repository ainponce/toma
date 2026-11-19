// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The Audio tab (design §5.4): a row for each track of sound of the take, with its volume (0 to 200 %) and Mute, and
/// whether the mix avoids clipping. The click sounds are set in the Cursor tab.
struct AudioTab: View {
    let model: EditorModel
    let audio: AudioPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.audioTracks.isEmpty {
                Text("This recording has no audio.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.audioTracks) { track in
                    let gain = audio.tracks[track.id] ?? TrackGain(gain: 1, muted: false)
                    PanelSection {
                        if track.isMicrophone {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Microphone")
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: track.deviceName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if track.isDevice {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("iPhone or iPad")
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: track.deviceName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("System Audio")
                                .font(.subheadline.weight(.semibold))
                        }
                        PanelSlider(
                            title: "Volume", model: model, value: PanelValues.percent(trackGain: gain.gain),
                            range: PanelValues.trackVolumeRange, unit: " %"
                        ) { model.setTrackVolume(track, percent: $0) }
                        .disabled(gain.muted)
                        Toggle("Mute", isOn: Binding(get: { gain.muted }, set: { model.setTrackMuted(track, $0) }))
                        if track.isMicrophone {
                            AudioCleanupRow(model: model, track: track, level: CleanupLevel(cleanup: gain.cleanup))
                        }
                    }
                }
                Divider()
                PanelSection {
                    AudioMasterRows(model: model, audio: audio)
                }
            }
        }
    }
}
