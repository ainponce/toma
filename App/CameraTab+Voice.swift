// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// What the Camera tab does to the document for the voice (phase 2 design §5.9): the sync offset is one step of
/// `VoiceCommands`; a drag of its bar is a gesture.
extension EditorModel {
    /// "Sync with Audio", in milliseconds.
    func setCameraSync(milliseconds: Int) {
        guard let document, let step = VoiceCommands.setSyncOffset(document, milliseconds: milliseconds) else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }
}

/// The camera's voice features in the Camera tab (phase 2 design §5.5 and §5.9, plan 2a task A12), under 2b's picture:
///
/// - **Sync with Audio:** from −300 to +300 ms in steps of 10, with its sign always written ("+40 ms") and what the sign
///   means. A drag of the bar is one edit.
/// - **Hide During Silences:** adds a Screen Only block in each silence of 3 s or more (`EditorVoice.hideCameraInSilences`),
///   and says how many it added.
struct CameraVoiceSection: View {
    let model: EditorModel

    @State private var finding = false
    @State private var result: Result?
    @State private var dragged: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Result: Equatable {
        case added(Int)
        case cannot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            sync
            Divider()
            hide
        }
    }

    // MARK: - Sync

    private var sync: some View {
        let value = Int((model.document?.camera.syncOffset ?? 0) / 1_000_000)
        let shown = dragged ?? value
        return PanelSection("Sync with Audio") {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Offset")
                    Spacer()
                    Text(verbatim: Self.label(milliseconds: shown))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(shown) },
                        set: { newValue in
                            let stepped = Int((newValue / Double(VoiceCommands.syncStep)).rounded()) * VoiceCommands.syncStep
                            guard stepped != shown else { return }
                            dragged = stepped
                            model.setCameraSync(milliseconds: stepped)
                        }),
                    in: Double(VoiceCommands.syncRange.lowerBound)...Double(VoiceCommands.syncRange.upperBound),
                    step: Double(VoiceCommands.syncStep),
                    onEditingChanged: { editing in
                        if editing {
                            model.beginGesture()
                        } else {
                            model.endGesture()
                            dragged = nil
                        }
                    }
                )
                .labelsHidden()
                .disabled(!model.canEdit)
                .accessibilityLabel(Text("Sync with Audio"))
                .accessibilityValue(Text(verbatim: Self.label(milliseconds: shown)))
            }
            Text("Positive: the camera is shown later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: value) { _, _ in
            if !model.isGesturing { dragged = nil }
        }
    }

    /// "+40 ms", "−40 ms" (a true minus sign) or "0 ms".
    static func label(milliseconds: Int) -> String {
        switch milliseconds {
        case 0: "0 ms"
        case 1...: "+\(milliseconds) ms"
        default: "\u{2212}\(-milliseconds) ms"
        }
    }

    // MARK: - Hide during silences

    private var hide: some View {
        let hasMicrophone = model.audioTracks.contains { $0.isMicrophone }
        let hasTranscript = model.document?.transcript != nil
        let possible = hasMicrophone || hasTranscript
        return PanelSection {
            Button {
                run()
            } label: {
                Label("Hide During Silences", systemImage: "rectangle.on.rectangle.slash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!possible || finding || !model.canEdit)
            .accessibilityHint(Text("Adds a Screen Only block to each silence of 3 seconds or more."))
            Group {
                if !possible {
                    Text("This recording has no microphone.")
                } else if finding {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finding the silences…")
                    }
                } else if let result {
                    switch result {
                    case let .added(count) where count > 0: Text("\(count) blocks added.")
                    case .added: Text("No silences of 3 s or more.")
                    case .cannot: Text("Couldn't find the silences.")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: finding)
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: result)
    }

    private func run() {
        finding = true
        result = nil
        Task {
            let count = await model.voice.hideCameraInSilences()
            finding = false
            result = count.map(Result.added) ?? .cannot
        }
    }
}
