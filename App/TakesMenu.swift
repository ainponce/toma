// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import SwiftUI

/// The Takes menu of the editor's bar (phase 3 design §8.1 and §8.2, 3d plan decision 6): first "Re-record from Here"
/// (⇧⌘R), with why it can't be done as its help when it can't; then each take of the project, "Take 2 · Nov 19, 14:02 ·
/// 3:12 · Unused" (its number, when it started, what it recorded without its pauses, and whether the sequence uses it),
/// each with "Use from Here" and "Add to End"; a take that recorded nothing is shown disabled, "Empty". The key is shown
/// under the command's name, never as the menu's key equivalent: ⇧⌘R is the editor's (`KeyboardCommands`), as M and ⌥← of
/// the Markers menu are.
struct TakesMenu: View {
    let model: EditorModel

    var body: some View {
        Menu {
            RerecordItem(model: model)
            Divider()
            ForEach(model.takes, id: \.id) { take in
                if take.isEmpty {
                    Button(Self.title(of: take)) {}
                        .disabled(true)
                } else {
                    Menu(Self.title(of: take)) {
                        Button(Self.useTitle) { model.useTake(take, fromHere: true) }
                        Button(Self.appendTitle) { model.useTake(take, fromHere: false) }
                    }
                    .disabled(!model.canEdit)
                }
            }
        } label: {
            Label("Takes", systemImage: "square.stack.3d.up")
        }
        .disabled(model.state != .ready)
        .help(Text("Takes"))
        .accessibilityLabel(Text("Takes"))
    }

    static var rerecordTitle: String { String(localized: "Re-record from Here") }
    static var useTitle: String { String(localized: "Use from Here", comment: "Takes menu: this take replaces the video from the playhead") }
    static var appendTitle: String { String(localized: "Add to End", comment: "Takes menu: this take goes after the end of the video") }

    /// "Take 2 · Nov 19, 14:02 · 3:12 · In Use", "Take 3 · Nov 19, 14:20 · 0:45 · Unused", "Take 4 · Nov 19, 14:31 ·
    /// Empty".
    static func title(of take: TakeInfo) -> String {
        let number = String(localized: "Take \(take.number)", comment: "Takes menu: a take of the project, by its place")
        let started = take.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        guard !take.isEmpty else {
            let empty = String(localized: "Empty", comment: "Takes menu: a take that recorded nothing")
            return [number, started, empty].joined(separator: " · ")
        }
        let duration = Timecode.duration(Double(take.duration) / 1e9)
        let use =
            take.inUse
            ? String(localized: "In Use", comment: "Takes menu: a take the video shows")
            : String(localized: "Unused", comment: "Takes menu: a take the video does not show")
        return [number, started, duration, use].joined(separator: " · ")
    }
}

/// "Re-record from Here", in a view of its own so that only it follows what can block it.
private struct RerecordItem: View {
    let model: EditorModel

    var body: some View {
        let block = model.rerecordBlock
        Button {
            model.rerecordFromHere()
        } label: {
            Label {
                Text(TakesMenu.rerecordTitle)
                Text(verbatim: "⇧⌘R")
            } icon: {
                Image(systemName: "arrow.counterclockwise.circle")
            }
        }
        .disabled(block != nil)
        .help(block.map(EditorModel.text(of:)) ?? "")
    }
}
