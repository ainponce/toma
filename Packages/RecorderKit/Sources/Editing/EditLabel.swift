// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The action an undo step is, for the Edit menu's "Undo «action»" (the 21 undo labels of design §5.11, and the 12 of the
/// 1c design §13.1 after them). Its raw value is the `label` of a `do` line of `edit-log.jsonl`, so the names never
/// change; the app localizes them.
public enum EditLabel: String, Codable, Sendable, CaseIterable {
    case split, delete, trim, speed
    case zoomAdd = "zoom.add", zoomMove = "zoom.move", zoomChange = "zoom.change", zoomDelete = "zoom.delete"
    case zoomRegenerate = "zoom.regenerate"
    case background = "style.background", padding = "style.padding", cornerRadius = "style.cornerRadius"
    case shadow = "style.shadow", frame = "style.frame"
    case cursor, camera, screen
    case volume = "audio.volume"
    case aspect, frameRate
    case applyDefaultStyle = "style.applyDefault"
    // 1c: the camera's layouts and look, and the named styles (plan 1c decision 8). Whether a block is instant and the
    // style of a Bubble block are `layoutChange`; a split's side and size, `cameraSplit`.
    case layoutAdd = "layout.add", layoutChange = "layout.change", layoutMove = "layout.move", layoutTrim = "layout.trim"
    case layoutDelete = "layout.delete"
    case cameraLayout = "camera.layout", cameraSplit = "camera.split", cameraMirror = "camera.mirror"
    case cameraBorder = "camera.border", cameraShadow = "camera.shadow", cameraChangesDeleteAll = "camera.changes.deleteAll"
    case styleApply = "style.apply"
}

/// What one command changes, before it is a line of the log: its changes, and the grouping key of design §6.4.
public struct EditStep: Equatable, Sendable {
    public var label: EditLabel
    /// What the command acts on, the path or the id: with `label`, the key that joins a burst of steps into one undo
    /// group (ten arrow presses in one field are one undo).
    public var target: String
    public var changes: [EditChange]

    public init(label: EditLabel, target: String, changes: [EditChange]) {
        self.label = label
        self.target = target
        self.changes = changes
    }
}
