// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The Markers menu of the editor's bar (phase 3 design §8.3): each marker with its name and its output time, a click
/// taking the playhead there. Disabled while it has nothing to list, which is all of the base of phase 3: the markers
/// feature (3d) lists them.
struct MarkersMenu: View {
    let model: EditorModel

    var body: some View {
        Menu {
        } label: {
            Label("Markers", systemImage: "bookmark")
        }
        .disabled(true)
        .help(Text("Markers"))
        .accessibilityLabel(Text("Markers"))
    }
}
