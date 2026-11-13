// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct TomaApp: App {
    var body: some Scene {
        MenuBarExtra("Toma", systemImage: "record.circle") {
            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
