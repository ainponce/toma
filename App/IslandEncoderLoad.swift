// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Recording
import SwiftUI

// The encoder's load in the open island (notch design §5.2): a dot in the footer, green or amber, and at the bottom
// of the settings what would lighten a high load, as buttons that make the change.

extension OpenPanelModel {
    /// What the selection would weigh on the encoder with the settings shown, before there is a take: the same
    /// estimate the take makes (`TakePlanner.loadItems` with `EncoderLoad.evaluate`), with the camera only if it
    /// is allowed and the chosen window at its size now.
    var load: EncoderLoadVerdict {
        var recorded = selection
        if camera.permission != .granted { recorded.camera = .off }
        let infos = displays.map(\.info)
        let items = TakePlanner.loadItems(recorded, settings: recordedQuick, displays: infos, windowSize: windowPixelSize)
        return EncoderLoad.evaluate(
            items, mainDisplayID: infos.first(where: \.isMain)?.id, budget: EncoderLoad.budget(defaults: .standard))
    }

    /// The chosen window in pixels at the scale the take records, in Window mode.
    private var windowPixelSize: CGSize? {
        guard selection.mode == .window, let window = chosenWindow else { return nil }
        return pixelSize(ofWindow: window)
    }

    /// Makes the changes `suggestions` say.
    func apply(_ suggestions: [LoadSuggestion]) {
        for suggestion in suggestions {
            switch suggestion {
            case .lowerDisplayRate(let displayID, let rate): quick.framesPerSecondByDisplay[displayID] = rate
            case .lowerCameraPreset(let preset): quick.cameraPreset = preset
            case .lowerCameraRate(let rate): quick.cameraFramesPerSecond = rate
            }
        }
    }
}

extension EncoderLoadVerdict {
    /// Frames may be dropped: high, or past the budget.
    var isHeavy: Bool {
        switch self {
        case .ok: false
        case .high, .over: true
        }
    }

    var ratio: Double {
        switch self {
        case .ok(let ratio), .high(let ratio, _), .over(let ratio, _): ratio
        }
    }

    var suggestions: [LoadSuggestion] {
        switch self {
        case .ok: []
        case .high(_, let suggestions), .over(_, let suggestions): suggestions
        }
    }
}

extension CameraPreset {
    /// "720p", "1080p", "4K".
    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p2160: "4K"
        }
    }
}

/// The footer's dot: green while the encoder keeps up, with how much of its budget the take would use; amber once
/// frames may be dropped, saying so. A click opens the settings, where the changes that lighten it are.
struct LoadIndicator: View {
    let verdict: EncoderLoadVerdict
    let showSettings: () -> Void
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: showSettings) {
            LoadLine(verdict: verdict, size: 11.5)
                .opacity(verdict.isHeavy ? 0.9 : 0.62)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: verdict.isHeavy)
    }
}

/// The dot and what it means: "Encoder load 42 %", or that it may be too much.
struct LoadLine: View {
    let verdict: EncoderLoadVerdict
    let size: Double

    var body: some View {
        let tint = verdict.isHeavy ? NoticePresentation.attention.tint : NoticePresentation.confirmation.tint
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .shadow(color: tint.opacity(0.6), radius: 3)
            if verdict.isHeavy {
                Text("This setup may be too much for the encoder.")
            } else {
                let percent = verdict.ratio.formatted(.percent.precision(.fractionLength(0)))
                Text("Encoder load \(percent)", comment: "How much of the encoder's budget the take would use, as 42 %")
                    .monospacedDigit()
            }
        }
        .font(.system(size: size))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// At the bottom of the settings: the load, and while it is high each change that would lighten it as a button
/// that makes it. The displays' suggestions are one button: it lowers every secondary display at once.
struct LoadSettingsSection: View {
    let panel: OpenPanelModel
    let verdict: EncoderLoadVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoadLine(verdict: verdict, size: 12)
                .opacity(verdict.isHeavy ? 1 : 0.75)
            let groups = Self.groups(of: verdict.suggestions)
            if !groups.isEmpty {
                HStack(spacing: 6) {
                    ForEach(groups.indices, id: \.self) { index in
                        Button { panel.apply(groups[index]) } label: { Self.title(of: groups[index]) }
                            .buttonStyle(GlassButtonStyle(compact: true))
                            .fixedSize()
                    }
                }
            }
        }
    }

    /// The displays' suggestions together, then the others one by one, in their order.
    private static func groups(of suggestions: [LoadSuggestion]) -> [[LoadSuggestion]] {
        let displays = suggestions.filter { if case .lowerDisplayRate = $0 { true } else { false } }
        let others = suggestions.filter { if case .lowerDisplayRate = $0 { false } else { true } }
        return (displays.isEmpty ? [] : [displays]) + others.map { [$0] }
    }

    /// One sentence for each kind of change.
    private static func title(of group: [LoadSuggestion]) -> Text {
        switch group.first {
        case .lowerDisplayRate(_, let rate)?:
            Text("Record secondary displays at \(rate) fps", comment: "A change that lightens the encoder's load")
        case .lowerCameraPreset(let preset)?:
            Text("Record the camera at \(preset.label)", comment: "A change that lightens the encoder's load: the camera's quality, as 1080p")
        case .lowerCameraRate(let rate)?:
            Text("Record the camera at \(rate) fps", comment: "A change that lightens the encoder's load")
        case nil:
            Text(verbatim: "")
        }
    }
}
