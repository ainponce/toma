// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import SwiftUI

/// The Replay as the island and Settings show it (fases 4 y 5 design §10.4): on in the settings, its N, what it does now
/// and why it is off or saved nothing.
struct ReplayLook: Equatable {
    var isEnabled: Bool
    var seconds: Int
    var phase: ReplayController.Phase
    var problem: ReplayController.Problem?

    /// It records its ring: the island shows its wings, or its pill, and Save the Last N s.
    var records: Bool {
        switch phase {
        case .on, .saving: true
        case .off, .starting, .suspended: false
        }
    }

    /// Save Replay is a shortcut: while it records, and while it is on in the settings but a problem holds it off, so
    /// the shortcut says why there is nothing to save instead of doing nothing.
    var answersShortcut: Bool {
        records || (isEnabled && phase == .off && problem.map(ReplayText.holdsItOff) == true)
    }
}

extension ReplayController {
    var look: ReplayLook { ReplayLook(isEnabled: isEnabled, seconds: seconds, phase: phase, problem: problem) }
}

/// The Replay's words, the island's and Settings'.
enum ReplayText {
    /// A length as the island and the menu say it: «15 s», «1 min», «2 min 5 s».
    static func length(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes == 0 {
            return String(localized: "\(seconds) s", comment: "A length of the Replay in seconds: «30 s»")
        }
        if rest == 0 {
            return String(localized: "\(minutes) min", comment: "A length of the Replay in minutes: «2 min»")
        }
        return String(localized: "\(minutes) min \(rest) s", comment: "A length of the Replay in minutes and seconds: «1 min 5 s»")
    }

    /// What VoiceOver says of the wings: «Replay on, last 30 seconds».
    static func spokenOn(_ seconds: Int) -> String {
        if seconds == 60 {
            return String(localized: "Replay on, last minute", comment: "VoiceOver, the island's Replay wings: it keeps the last minute")
        }
        if seconds % 60 == 0 {
            return String(
                localized: "Replay on, last \(seconds / 60) minutes",
                comment: "VoiceOver, the island's Replay wings: it keeps the last minutes, two or more")
        }
        return String(
            localized: "Replay on, last \(seconds) seconds", comment: "VoiceOver, the island's Replay wings: it keeps the last seconds")
    }

    /// The island's button and Settings: «Save the Last 30 s».
    static func saveTheLast(_ seconds: Int) -> String {
        String(localized: "Save the Last \(length(seconds))", comment: "The island's button that saves the Replay's last seconds: «30 s», «1 min»")
    }

    /// Why it is off, or why the last save saved nothing.
    static func problem(_ problem: ReplayController.Problem) -> String {
        switch problem {
        case .noScreenRecording:
            String(localized: "Toma isn't allowed to record the screen.", comment: "Why the Replay is off")
        case .encoderBusy:
            String(
                localized: "What it would record is more than this Mac can encode at once.",
                comment: "Why the Replay is off: its sources are too much for the encoder")
        case .diskFull:
            String(localized: "The disk is almost full.", comment: "Why the Replay is off")
        case .couldNotStart:
            String(localized: "Its sources couldn't start.", comment: "Why the Replay is off: the screen did not start")
        case .saveFailed:
            String(localized: "Couldn't save: nothing was saved.", comment: "The Replay's last save failed")
        case .tooShort:
            String(
                localized: "Less than a second was recorded: nothing was saved.",
                comment: "The Replay's last save: it had less than a second")
        }
    }

    /// It stopped, or could not start, and stays off: «The Replay is off. The disk is almost full.»
    static func off(_ problem: ReplayController.Problem) -> String {
        String(
            localized: "The Replay is off. \(ReplayText.problem(problem))",
            comment: "The capsule under the island when the Replay stops by itself, or its shortcut is pressed while it is off: why")
    }

    /// A problem that keeps it off until the next recording, the user turning it on again, or the next launch.
    static func holdsItOff(_ problem: ReplayController.Problem) -> Bool {
        switch problem {
        case .noScreenRecording, .encoderBusy, .diskFull, .couldNotStart: true
        case .saveFailed, .tooShort: false
        }
    }
}

// MARK: - At rest

/// The island at rest under a notch while the Replay records: a gray dot in the left wing and «↺ 30 s» in the right, the
/// recording wings' layout without the time, the red or the microphone.
struct ReplayWings: View {
    let seconds: Int
    let notchWidth: Double

    var body: some View {
        HStack(spacing: 0) {
            // Where the recording wings have their dot.
            ReplayDot()
                .padding(.horizontal, 10)
                .frame(width: IslandGeometry.wingWidth, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            ReplayLength(seconds: seconds)
                .padding(.horizontal, 10)
                .frame(width: IslandGeometry.wingWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .replayAccessibility(seconds: seconds)
    }
}

/// The island at rest on a screen without a notch while the Replay records: the pill, with the gray dot and «↺ 30 s».
struct ReplayPill: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 8) {
            ReplayDot()
            ReplayLength(seconds: seconds)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .replayAccessibility(seconds: seconds)
    }
}

/// The Replay's dot: gray, still. It records, but nothing is kept unless it is saved.
private struct ReplayDot: View {
    var body: some View {
        Circle()
            .fill(Color(white: 0.62))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

/// «↺ 30 s».
private struct ReplayLength: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .bold))
            Text(verbatim: ReplayText.length(seconds))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1)
        .fixedSize()
    }
}

extension View {
    /// One element for VoiceOver: «Replay on, last 30 seconds».
    fileprivate func replayAccessibility(seconds: Int) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: ReplayText.spokenOn(seconds)))
    }
}

// MARK: - The open island

/// The open island's Replay, at the trailing end of its header (its footer has no room for it and Save in Spanish):
/// «↺ Replay · 30 s», a menu of the lengths, and its switch. Why it is off, or why the last save saved nothing, is in the
/// help of a warning beside it.
struct IslandReplayRow: View {
    let model: IslandModel

    var body: some View {
        let look = model.replayLook
        HStack(spacing: 6) {
            Menu {
                Picker(selection: Binding(get: { look.seconds }, set: { model.replay.setSeconds($0) })) {
                    ForEach(ReplayPreferences.validSeconds, id: \.self) { seconds in
                        Text(verbatim: ReplayText.length(seconds)).tag(seconds)
                    }
                } label: {
                    Text("Keep the Last", comment: "The island's menu of how much the Replay keeps")
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Replay", comment: "The island's switch of the Replay, before its length")
                    Text(verbatim: "· " + ReplayText.length(look.seconds))
                        .monospacedDigit()
                        .opacity(0.65)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .opacity(0.5)
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("How long the Replay keeps", comment: "Help of the island's Replay menu"))
            if let problem = look.problem, look.isEnabled {
                Image(systemName: NoticePresentation.attention.symbol)
                    .font(.system(size: 11))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(NoticePresentation.attention.tint)
                    .help(Text(verbatim: ReplayText.problem(problem)))
                    .accessibilityLabel(Text(verbatim: ReplayText.problem(problem)))
            }
            Toggle(isOn: Binding(get: { look.isEnabled }, set: { model.replay.setEnabled($0) })) {
                Text("Replay", comment: "The island's switch of the Replay, before its length")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 32)
        .background(Capsule().fill(Color.white.opacity(0.09)).overlay(Capsule().stroke(Color.white.opacity(0.13))))
    }
}

/// While the Replay records, in the open island's footer before Record: «Save the Last 30 s» with its shortcut.
struct IslandReplaySave: View {
    let model: IslandModel

    var body: some View {
        let look = model.replayLook
        Button { model.saveReplay() } label: {
            Label {
                HStack(spacing: 6) {
                    Text(verbatim: ReplayText.saveTheLast(look.seconds))
                    if let shortcut = model.hotKeys.bindings.combos[.saveReplay] {
                        KeyCap(text: shortcut.shownString)
                    }
                }
            } icon: {
                Image(systemName: "arrow.counterclockwise")
            }
        }
        .buttonStyle(GlassButtonStyle())
        .disabled(look.phase == .saving)
    }
}
