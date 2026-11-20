// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The Takes menu of the editor's bar (phase 3 design §8.1): each take of the project (its number, date and duration, in
/// use or unused) with "Add to End" and "Use from Here". Disabled while it has nothing to list, which is all of the base
/// of phase 3: the takes feature (3d) lists them.
struct TakesMenu: View {
    let model: EditorModel

    var body: some View {
        Menu {
        } label: {
            Label("Takes", systemImage: "square.stack.3d.up")
        }
        .disabled(true)
        .help(Text("Takes"))
        .accessibilityLabel(Text("Takes"))
    }
}
