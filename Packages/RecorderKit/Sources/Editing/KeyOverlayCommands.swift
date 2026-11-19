// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the keys on screen (phase 2 design §7.4): which keys show, where and how big. A pure function of the
/// document that gives the step that does it (`EditStep`), or `nil` when nothing changes.
public enum KeyOverlayCommands {
    /// Sets the fields given, one `set` each, in one step (`.keysOverlay`, target `/keys`).
    public static func set(
        _ doc: EditDocument, mode: KeyOverlayMode? = nil, position: KeyOverlayPosition? = nil, size: OverlaySize? = nil
    ) -> EditStep? {
        var changes = DocumentChanges()
        if let mode { changes.set(["keys", "mode"], from: doc.keys.mode, to: mode) }
        if let position { changes.set(["keys", "position"], from: doc.keys.position, to: position) }
        if let size { changes.set(["keys", "size"], from: doc.keys.size, to: size) }
        return changes.step(label: .keysOverlay, target: "/keys")
    }
}
