// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The action an undo step is, for the Edit menu's "Undo «action»" (the 21 undo labels of design §5.11, the 12 of the
/// 1c design §13.1 after them, the 25 of phase 2 design §8 after those, and the 25 of phase 3 design §10 last). Its raw
/// value is the `label` of a `do` line of `edit-log.jsonl`, so the names never change; the app localizes them.
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
    // Phase 2 design §8 (plan decision 19), in its order: the transcription and the captions (2a), the camera's and the
    // sound's new settings, the screen's framing (2b), the privacy blocks, the keys on screen and the typing sped up (2c).
    case transcriptCreate = "transcript.create", transcriptCut = "transcript.cut", transcriptRestore = "transcript.restore"
    case transcriptWord = "transcript.word", transcriptBreak = "transcript.break", transcriptFillers = "transcript.fillers"
    case transcriptPauses = "transcript.pauses"
    case captionsShow = "captions.show", captionsStyle = "captions.style"
    case cameraHideSilences = "camera.hideSilences", cameraBackground = "camera.background", cameraFraming = "camera.framing"
    case cameraLook = "camera.look", cameraSync = "camera.sync"
    case audioCleanup = "audio.cleanup", audioNormalize = "audio.normalize"
    case styleReframe = "style.reframe"
    case privacyAdd = "privacy.add", privacyChange = "privacy.change", privacyMove = "privacy.move", privacyTrim = "privacy.trim"
    case privacyDelete = "privacy.delete", privacyAuto = "privacy.auto"
    case keysOverlay = "keys.overlay"
    case speedTyping = "speed.typing"
    // Phase 3 design §10 (plan decision 17), in its order: the annotations and the clips with content (3a), the zoom's
    // mode (3b), the sound's stretches, cuts and music (3c), the takes and the markers (3d).
    case annotationAdd = "annotation.add", annotationChange = "annotation.change", annotationMove = "annotation.move"
    case annotationTrim = "annotation.trim", annotationLayer = "annotation.layer", annotationDelete = "annotation.delete"
    case clipFreeze = "clip.freeze", clipCard = "clip.card", clipMedia = "clip.media", clipContent = "clip.content"
    case zoomMode = "zoom.mode"
    case audioRange = "audio.range", audioShift = "audio.shift"
    case musicAdd = "music.add", musicChange = "music.change", musicMove = "music.move", musicTrim = "music.trim"
    case musicDelete = "music.delete", musicDucking = "music.ducking"
    case takeRerecord = "take.rerecord", takeUse = "take.use"
    case markerAdd = "marker.add", markerRename = "marker.rename", markerMove = "marker.move", markerDelete = "marker.delete"
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
