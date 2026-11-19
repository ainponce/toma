// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// What the Audio tab does to the document for the voice (phase 2 design §5.6 and §5.7): each is one of `VoiceCommands`'
/// steps.
extension EditorModel {
    /// "Noise Cleanup": Off, Gentle or Strong, for one microphone.
    func setCleanup(_ track: AudioTrackRow, _ level: CleanupLevel) {
        guard let document, let step = VoiceCommands.setCleanup(document, track: track.id, level) else { return }
        perform(step)
    }

    /// "Normalize Volume".
    func setNormalize(_ on: Bool) {
        guard let document, let step = VoiceCommands.setNormalize(document, on) else { return }
        perform(step)
    }
}

/// "Noise Cleanup" of a microphone, in the Audio tab: Off, Gentle or Strong as a segmented control (phase 2 design §5.6),
/// and under it "Cleaning the audio… 40 %" while the clean voice is made (the preview sounds as recorded meanwhile), or
/// why it cannot be chosen when this Mac has no system voice isolation.
struct AudioCleanupRow: View {
    let model: EditorModel
    let track: AudioTrackRow
    let level: CleanupLevel

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let voice = model.voice
        let available = voice.isolationAvailable
        let progress = level == .off ? nil : voice.cleanupProgress[track.id]
        VStack(alignment: .leading, spacing: 6) {
            Text("Noise Cleanup")
                .padding(.top, 6)
            HStack(spacing: 2) {
                ForEach(CleanupLevel.allCases, id: \.self) { option in
                    segment(option, enabled: available || option == .off)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Noise Cleanup"))
            if !available {
                Text("This Mac doesn't have the system's voice isolation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Self.progressText(progress))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: progress != nil)
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: level)
    }

    static func progressText(_ fraction: Double) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        return String(format: String(localized: "Cleaning the audio… %lld %%", comment: "The voice without noise being made"), percent)
    }

    private func segment(_ option: CleanupLevel, enabled: Bool) -> some View {
        let isSelected = option == level
        return Button {
            model.setCleanup(track, option)
        } label: {
            // Laid out as the chosen word (bolder) whether chosen or not, so choosing never rewraps it.
            Text(Self.name(option))
                .fontWeight(.semibold)
                .hidden()
                .overlay { Text(Self.name(option)).fontWeight(isSelected ? .semibold : .regular) }
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.28))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                            .matchedGeometryEffect(id: "cleanup", in: indicator)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || !model.canEdit)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(Self.name(option)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func name(_ level: CleanupLevel) -> LocalizedStringKey {
        switch level {
        case .off: "Cleanup Off"
        case .gentle: "Cleanup Gentle"
        case .strong: "Cleanup Strong"
        }
    }
}

/// "Normalize Volume" with "Avoid Clipping" under it, at the end of the Audio tab (phase 2 design §5.7): while the loudness
/// is measured it says "Measuring the volume… 30 %" (the preview sounds as it is meanwhile), and with Normalize on the
/// limiter is on and cannot be turned off.
struct AudioMasterRows: View {
    let model: EditorModel
    let audio: AudioPlan

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = audio.normalize ? model.voice.loudnessProgress : nil
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Normalize Volume", isOn: Binding(get: { audio.normalize }, set: { model.setNormalize($0) }))
            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Self.progressText(progress))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
            Toggle("Avoid Clipping", isOn: Binding(get: { audio.limiter || audio.normalize }, set: { model.setLimiter($0) }))
                .disabled(audio.normalize)
            if audio.normalize {
                Text("Normalize keeps it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: progress != nil)
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: audio.normalize)
    }

    static func progressText(_ fraction: Double) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        return String(format: String(localized: "Measuring the volume… %lld %%", comment: "The loudness being measured"), percent)
    }
}
