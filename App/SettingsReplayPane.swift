// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import SwiftUI

/// The Replay as a showcase makes it up for its pane: how it looks, and what it records.
struct ReplayShowcase {
    var look: ReplayLook
    var kinds: [TrackKind]
}

/// Settings ▸ Replay (fases 4 y 5 design §10.4): the switch, how long it keeps (15 s to 5 min), what it records (the
/// sources of the last recording, listed, never chosen here), its state, its shortcut, and the note that macOS shows the
/// screen being recorded meanwhile. Every change applies at once (`ReplayController`).
struct SettingsReplayPane: View {
    let model: SettingsModel
    let replay: ReplayController

    var body: some View {
        let look = model.showcaseReplay?.look ?? replay.look
        Section {
            Toggle(isOn: Binding(get: { look.isEnabled }, set: { replay.setEnabled($0) })) {
                Text("Replay", comment: "Settings ▸ Replay: its switch")
                Text(
                    "Keeps the last seconds of the screen, to save them as a project with a shortcut.",
                    comment: "Under the switch of the Replay in Settings")
            }
            Picker(selection: Binding(get: { look.seconds }, set: { replay.setSeconds($0) })) {
                ForEach(ReplayPreferences.validSeconds, id: \.self) { seconds in
                    Text(verbatim: ReplayText.length(seconds)).tag(seconds)
                }
            } label: {
                Text("Save the Last", comment: "Settings ▸ Replay: how long it keeps, before 15 s, 30 s, 1 min…")
            }
            .pickerStyle(.segmented)
            LabeledContent {
                Text(verbatim: sources(look))
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("Records", comment: "Settings ▸ Replay: what it records, before the list of sources")
                Text("Same as the last recording", comment: "Settings ▸ Replay: where its sources come from")
            }
            if let state = state(look) {
                LabeledContent {
                    if look.problem != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    } else if look.records {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                } label: {
                    Text("Status", comment: "Settings ▸ Replay: what it does now")
                    state
                }
            }
            ShortcutRow(model: model, action: .saveReplay)
        } footer: {
            SettingsFooter(
                Text(
                    "While it's on, macOS shows that Toma is recording the screen (and the camera or the microphone if it uses them). Nothing leaves the Mac; what isn't saved is deleted.",
                    comment: "Under Settings ▸ Replay: the system's recording indicator stays on"))
        }
    }

    /// What it records now, or would record if it started now: «Display, Camera and Microphone».
    private func sources(_ look: ReplayLook) -> String {
        let kinds: [TrackKind]
        if let showcase = model.showcaseReplay {
            kinds = showcase.kinds
        } else if look.records {
            kinds = replay.recordedKinds
        } else {
            let selection = replay.plannedSelection
            // A display, or an area of one (`ReplaySelection` never gives a window or an iPhone).
            var planned: [TrackKind] = selection.area != nil || !selection.displayIDs.isEmpty ? [.display] : []
            if selection.camera != .off { planned.append(.camera) }
            if selection.microphone != .off { planned.append(.microphone) }
            if selection.systemAudio != .off { planned.append(.systemAudio) }
            kinds = planned
        }
        return TrackKind.listed(kinds) ?? String(localized: "Nothing", comment: "Settings ▸ Replay: it records no source")
    }

    /// What it does now, or why it is off; nothing while it is off and fine.
    private func state(_ look: ReplayLook) -> Text? {
        if let problem = look.problem {
            let text = Text(verbatim: ReplayText.problem(problem))
            guard look.isEnabled, ReplayText.holdsItOff(problem) else { return text }
            return Text(
                "\(text) It tries again after the next recording.",
                comment: "Settings ▸ Replay: why it is off, then when it tries again")
        }
        switch look.phase {
        case .off: return nil
        case .starting: return Text("Starting…", comment: "Settings ▸ Replay: its sources are starting")
        case .on: return Text("Recording the last \(ReplayText.length(look.seconds))", comment: "Settings ▸ Replay: it records: «30 s»")
        case .saving: return Text("Saving…", comment: "Settings ▸ Replay: it saves its last seconds")
        case .suspended:
            return Text(
                "Waiting: it starts again once the recording ends, or the Mac wakes or is unlocked.",
                comment: "Settings ▸ Replay: a take, sleep or a locked screen stopped it for now")
        }
    }
}
