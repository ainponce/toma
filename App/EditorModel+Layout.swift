// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Editing
import Foundation
import ProjectFormat

/// What the Camera tab does to the layouts and the camera's look (design §5.6): each control is one step of
/// `LayoutCommands` or `CameraLookCommands`, and a bar is a gesture, as the others of the panel.
extension EditorModel {
    /// The id of the layout block selected on the track, if any.
    var selectedLayoutBlock: String? {
        if case let .layoutBlock(id)? = selection { id } else { nil }
    }

    /// Applies `step`: inside a gesture it is the gesture's step, otherwise an edit.
    private func apply(_ step: EditStep?) {
        guard let step else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// A tile of Disposición: the layout of the block or of the project (`target`), a block's is then the last one chosen.
    func setLayoutKind(_ kind: LayoutKind, target: LayoutEditTarget) {
        guard let document, let map = panelTimeMap else { return }
        switch target {
        case let .block(id, _):
            apply(LayoutCommands.setKind(document, id: id, kind, timeMap: map))
            rememberBlockLayout(kind)
        case .project:
            apply(LayoutCommands.setProjectLayout(document, kind))
        }
    }

    /// A new layout block (design §5.5): from a double click on the Camera track (`click`), from "Disposición ▾" (`kind`) or
    /// from the shortcuts (`kind`, at the playhead or over the marked range). It is the one selected; its layout is the last
    /// one chosen for a block (`LayoutTrackRules.newBlock`), and `kind`, when given, is chosen now.
    @discardableResult
    func addLayoutBlock(click: Int64? = nil, kind: LayoutKind? = nil) -> Bool {
        guard canEdit, let document, let map = panelTimeMap else { return false }
        let plan = LayoutTrackRules.newBlock(
            playhead: playheadNanoseconds, click: click, marks: timelineMarks.range, lastKind: kind ?? lastBlockLayout)
        let step = plan.range.map { LayoutCommands.add(document, kind: plan.kind, output: $0, timeMap: map, makeID: Self.newID) }
            ?? LayoutCommands.add(document, kind: plan.kind, at: plan.start, timeMap: map, makeID: Self.newID)
        guard let step, perform(step) != .refused else { return false }
        selection = .layoutBlock(step.target)
        rememberBlockLayout(plan.kind)
        return true
    }

    /// The edge of block `id` brought to the playhead (VoiceOver's "trim"), in one step.
    @discardableResult
    func trimLayoutBlock(_ id: String, edge: ClipEdge) -> Bool {
        guard canEdit, let document, let map = panelTimeMap,
            let step = LayoutCommands.trim(document, id: id, edge: edge, toOutput: playheadNanoseconds, timeMap: map)
        else { return false }
        return perform(step) != .refused
    }

    /// Transición: Suave · Instantánea.
    func setLayoutInstant(_ id: String, _ instant: Bool) {
        guard let document else { return }
        apply(LayoutCommands.setInstant(document, id: id, instant))
    }

    /// "Delete Block": the selection goes with it.
    func deleteLayoutBlock(_ id: String) {
        guard let document else { return }
        apply(LayoutCommands.delete(document, ids: [id]))
    }

    /// Lado de la cámara of the block (`id`) or of the project's layout (`nil`).
    func setSplitSide(_ side: CameraSide, id: String?) {
        guard let document else { return }
        apply(LayoutCommands.setSplit(document, id: id, side: side))
    }

    /// Tamaño de la cámara: `nil`, Automático; or a percentage from 25 to 60.
    func setSplitShare(percent: Int?, id: String?) {
        guard let document else { return }
        apply(LayoutCommands.setSplit(document, id: id, share: .some(percent.map(PanelValues.splitShare(percent:)))))
    }

    /// The bubble's style where `target` says: the Bubble block's own, or what 1b edits at the playhead.
    func setBubbleStyle(_ style: CameraStyle, target: BubbleEditTarget) {
        switch target {
        case let .block(id, _):
            guard let document else { return }
            apply(LayoutCommands.setBubbleStyle(document, id: id, style))
        case .initial, .change:
            setCameraStyle(style)
        }
    }

    func setCameraMirror(_ on: Bool) {
        guard let document else { return }
        apply(CameraLookCommands.setMirror(document, on))
    }

    func setCameraBorder(slider: Int) {
        guard let document else { return }
        apply(CameraLookCommands.setBorderWidth(document, PanelValues.cameraBorder(slider: slider)))
    }

    func setCameraBorderColor(_ color: RGBA) {
        guard let document else { return }
        apply(CameraLookCommands.setBorderColor(document, color))
    }

    func setCameraShadow(slider: Int) {
        guard let document else { return }
        apply(CameraLookCommands.setShadow(document, PanelValues.cameraShadow(slider: slider)))
    }

    /// "Delete All Changes": one step, one undo.
    func deleteAllCameraChanges() {
        guard let document else { return }
        apply(CameraLookCommands.deleteAllChanges(document))
    }

    /// The layouts' timeline of the document, for what the list of changes says of the blocks (`hiddenBy`).
    var layoutTimeline: LayoutTimeline? {
        guard let document, let map = panelTimeMap, let take = panelSession?.project.take else { return nil }
        return LayoutTimeline(document: document, take: take, timeMap: map, cameraReadable: true)
    }
}
