// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import Render

/// What the editor does with the annotations from the timeline (phase 3 design §5.6, plan 3a Task A12): the selection,
/// Delete, Duplicate and the order of the layers (the Annotations track's menu and its keys); and from the preview and
/// the Annotations tab (Task A13): adding one at the playhead, an image or a clip dropped over the video, and the arrow
/// keys. Each is one step of `AnnotationCommands`.
extension EditorModel {
    /// Annotation `id` is the one selected; with `showingIt`, the playhead goes into it (a double click on the track), so
    /// the preview shows it: where it already is if the output shows the annotation there, else the first frame of the grid
    /// once it is all in (its entrance over, `AnnotationTiming.transition` or half of it if it is shorter), inside it.
    func selectAnnotation(_ id: String, showingIt: Bool) {
        selection = .annotations([id])
        guard showingIt, let document, let annotation = document.annotations.items.first(where: { $0.id == id }),
            let output = TimelineAnnotationItems.range(of: id, in: document)
        else { return }
        let map = TimeMap(sequence: document.sequence)
        let playhead = playheadNanoseconds
        if output.contains(playhead), AnnotationTiming.state(of: annotation, atOutput: playhead, document: document, timeMap: map) != nil {
            return
        }
        let rate = document.frameRate
        func firstFrame(atOrAfter τ: Int64) -> Int {
            var frame = Int((Double(τ) * Double(rate) / 1e9).rounded(.up))
            while Int64(TimeMap.frameTime(frame, frameRate: rate)) < τ { frame += 1 }
            return frame
        }
        let length = output.upperBound - output.lowerBound
        let shown = output.lowerBound + min(AnnotationTiming.transition, length / 2)
        var frame = firstFrame(atOrAfter: shown)
        if Int64(TimeMap.frameTime(frame, frameRate: rate)) >= output.upperBound { frame = firstFrame(atOrAfter: output.lowerBound) }
        seek(frame: frame)
    }

    /// Deletes the annotations selected, in one step (⌫ and the track's menu).
    func deleteSelectedAnnotations() {
        guard case .annotations? = selection else { return }
        deleteSelection()
    }

    /// Duplicates the annotations selected, in one step: the copies are the ones selected then.
    func duplicateSelectedAnnotations() {
        guard canEdit, !isGesturing, let document, case let .annotations(ids)? = selection,
            let step = AnnotationCommands.duplicate(document, ids: ids, makeID: Self.newID), perform(step) != .refused
        else { return }
        selection = .annotations(Set(step.target.split(separator: ",").map(String.init)))
    }

    /// Moves the one annotation selected in the order of its group (Bring Forward, Send Backward, Bring to Front, Send to
    /// Back); nothing with none or several.
    func reorderSelectedAnnotation(_ move: AnnotationCommands.LayerMove) {
        guard canEdit, !isGesturing, let document, case let .annotations(ids)? = selection, ids.count == 1, let id = ids.first,
            let step = AnnotationCommands.reorder(document, id: id, move)
        else { return }
        perform(step)
    }

    // MARK: - From the preview and the tab (Task A13)

    /// A new annotation of `new` at the playhead, selected (plan 3a decision 8): stuck to the recording over a stretch of
    /// a take, of the output elsewhere, with the place and the look of `AnnotationDefaults` in its space as the frame at
    /// the playhead draws it (so a step is round); a text's and a bubble's string is "Text".
    func addAnnotation(_ new: NewAnnotation) {
        guard canEdit, !isGesturing, let document else { return }
        let kind = AnnotationDefaults.kind(new, text: String(localized: "Text"))
        let now = playheadNanoseconds
        let space = annotationSpace(for: kind, atOutput: now, in: document)
        let rect = AnnotationDefaults.rect(for: kind, aspect: nil, spaceAspect: space.map { $0.width / $0.height } ?? 16.0 / 9)
        guard let step = AnnotationCommands.add(document, kind, atOutput: now, rect: rect, makeID: Self.newID) else {
            // Less than 0.3 s of output left at the playhead.
            NSSound.beep()
            return
        }
        guard perform(step) != .refused else { return }
        selection = .annotations([step.target])
    }

    /// The image or the clip at `url` over the video at the playhead (phase 3 design §5.4, plan 3a decision 8), selected:
    /// copied into the project (`EditSession.importAsset`, a clip by its extension, an image otherwise), 0.3 of its space
    /// wide with its picture's proportion (`MediaInfo`, off the main thread) and centred at `point` (fractions of the
    /// output frame; in the middle without one), stuck to the recording over a stretch of a take (an image) and of the
    /// output elsewhere (a clip always), a clip as long as its file. Whether it was added; `true` too when it could not
    /// be saved or the project cannot be edited, which the session and the banner say themselves.
    func addOverlay(from url: URL, at point: NormalizedPoint?) async -> Bool {
        guard canEdit, let session = panelSession else { return true }
        let video = ContentClipTrackRules.isVideoFile(url)
        let path: String
        switch await session.importAsset(url, kind: video ? .video : .image) {
        case let .imported(imported): path = imported
        case .notAnImage, .notALUT, .notPlayable: return false
        case .saveFailed, .notEditable: return true
        }
        guard let package = overlayProject?.package else { return true }
        let kind: AnnotationKind
        var aspect: Double?
        if video {
            guard let info = await MediaInfo.probe(path, in: package) else { return false }
            kind = AnnotationDefaults.clip(asset: path, fileDuration: info.duration)
            aspect = info.size.map { Double($0.x) / Double($0.y) }
        } else {
            kind = AnnotationDefaults.image(asset: path)
            aspect = await MediaInfo.imageSize(path, in: package).map { Double($0.x) / Double($0.y) }
        }
        // The document and the playhead as they are now that it is in the project.
        guard canEdit, !isGesturing, let document else { return true }
        let now = playheadNanoseconds
        let space = annotationSpace(for: kind, atOutput: now, in: document)
        var rect = AnnotationDefaults.rect(for: kind, aspect: aspect, spaceAspect: space.map { $0.width / $0.height } ?? 16.0 / 9)
        if let point, let space, let output = outputSize(atOutput: now), space.width > 0, space.height > 0 {
            // The point of the output in the annotation's space.
            let x = (point.x * output.x - space.x) / space.width, y = (point.y * output.y - space.y) / space.height
            if x.isFinite, y.isFinite {
                rect.x = x - rect.width / 2
                rect.y = y - rect.height / 2
            }
        }
        guard let step = AnnotationCommands.add(document, kind, atOutput: now, rect: rect, makeID: Self.newID),
            perform(step) != .refused
        else { return false }
        selection = .annotations([step.target])
        return true
    }

    /// ← → ↑ ↓ (⇧: 10) and ⇧↑ ⇧↓ over the preview with annotations selected (plan 3a decision 16): those the frame at the
    /// playhead shows move `points` points of the preview (x right, y down), in one step; the playhead stays. Whether the
    /// key was theirs: `false` with none shown there (or playing), so the key does what it did in 1b; `true` when they
    /// are shown, even where they cannot move further.
    func nudgeSelectedAnnotations(points: SIMD2<Double>) -> Bool {
        guard canEdit, !isGesturing, !isPlaying, let document, case let .annotations(ids)? = selection, let scene = shownScene,
            points.x.isFinite, points.y.isFinite, points != .zero
        else { return false }
        let view = previewLayer.bounds.size
        guard view.width > 0, view.height > 0 else { return false }
        let frame = scene.frame(at: Double(playheadNanoseconds) / 1e9) { _ in true }
        let pixels = points * SIMD2(Double(frame.outputSize.x) / Double(view.width), Double(frame.outputSize.y) / Double(view.height))
        var deltas: [String: SIMD2<Double>] = [:]
        for drawn in DrawnAnnotation.all(in: frame) where ids.contains(drawn.layer.id) {
            let space = drawn.space
            guard space.width > 0, space.height > 0 else { continue }
            deltas[drawn.layer.id] = pixels / SIMD2(space.width, space.height)
        }
        guard !deltas.isEmpty else { return false }
        if let step = AnnotationCommands.nudge(document, by: deltas) { perform(step) }
        return true
    }

    /// The size of the frame the scene shown draws at output instant `now`, in its pixels.
    private func outputSize(atOutput now: Int64) -> SIMD2<Double>? {
        guard let scene = shownScene else { return nil }
        let size = scene.outputSize
        return size.x > 0 && size.y > 0 ? SIMD2(Double(size.x), Double(size.y)) : nil
    }

    /// The space a new annotation of `kind` made at output instant `now` is measured in, in output pixels of the frame
    /// the scene shown draws there: over a stretch of a take (not a clip, which is of the output), where the whole content
    /// of the screen drawn would be (`AnnotationGeometry.contentSpace`, as `AnnotationScene` places it); otherwise, or
    /// without a screen in that frame, the output frame. `nil` without a scene.
    private func annotationSpace(for kind: AnnotationKind, atOutput now: Int64, in document: EditDocument) -> Rect? {
        guard let scene = shownScene else { return nil }
        let frame = scene.frame(at: Double(now) / 1e9) { _ in true }
        let output = AnnotationGeometry.outputSpace(outputSize: SIMD2(Double(frame.outputSize.x), Double(frame.outputSize.y)))
        if case .clip = kind { return output }
        return contentSpace(of: frame, atOutput: now, in: document) ?? output
    }

    /// Where `frame` (the scene shown's, at output instant `now`) would draw the whole content of its screen, in its
    /// output pixels (`AnnotationGeometry.contentSpace`): the space of an annotation stuck to the recording there. `nil`
    /// over anything but a stretch of a take, or without a screen in that frame.
    private func contentSpace(of frame: RenderFrame, atOutput now: Int64, in document: EditDocument) -> Rect? {
        let map = TimeMap(sequence: document.sequence)
        guard let (clip, source) = map.source(atOutput: now), document.sequence.indices.contains(clip),
            document.sequence[clip].content == nil, !frame.coveredByCamera, let drawn = frame.drawnScreen,
            let project = playheadProject, let screens = screensByTake[project.take.id]
        else { return nil }
        let points = StagePoints(take: project.take, document: document, screens: screens, contentRatio: .some(contentRatio(of: document)))
        let content = points.shownScreen(at: source).flatMap { $0.track == drawn.trackID ? $0.view.crop : nil } ?? drawn.crop
        return AnnotationGeometry.contentSpace(contentCrop: content, layerCrop: drawn.crop, drawnRect: drawn.rect)
    }

    // MARK: - From the Annotations tab (Task A14)

    /// The annotations selected, by id; none when something else is.
    var selectedAnnotationIDs: Set<String> {
        if case let .annotations(ids)? = selection { ids } else { [] }
    }

    /// The moves of the layers' order (Bring Forward, Send Backward, Bring to Front, Send to Back) that change something
    /// for the one annotation selected; none with none or several, or while the project cannot be edited.
    var possibleLayerMoves: Set<AnnotationCommands.LayerMove> {
        let ids = selectedAnnotationIDs
        guard canEdit, ids.count == 1, let id = ids.first, let document else { return [] }
        let moves: [AnnotationCommands.LayerMove] = [.forward, .backward, .front, .back]
        return Set(moves.filter { AnnotationCommands.reorder(document, id: id, $0) != nil })
    }

    /// Annotation `id` changed by `edit` (`AnnotationCommands.change`, held to what the document allows): a step of the
    /// gesture while one lasts (a slider of the inspector being dragged; one that brings it back to how it was shows the
    /// document as it is), otherwise one of its own.
    func changeAnnotation(_ id: String, _ edit: (inout Annotation) -> Void) {
        guard canEdit, let document else { return }
        let step = AnnotationCommands.change(document, id: id, edit)
        if isGesturing {
            updateGesture(step)
        } else if let step {
            perform(step)
        }
    }

    /// The inspector's Stick to the Recording and Whole Video (phase 3 design §5.1, plan 3a decision 2): annotation `id`
    /// anchored as `choice` says (`AnnotationCommands.setAnchor`), where it is seen, in one step: carried from the space a
    /// frame that shows it draws it in to the space of its new anchor in that same frame, its sizes with it
    /// (`AnnotationInspectorRules.reanchored`), so it does not jump. That frame is the one at the playhead when it shows
    /// the annotation; otherwise the first of the grid once it is all in. Without a screen to stick to in that frame, it
    /// keeps its numbers. The system beeps if it cannot be anchored so (a clip to the recording, a range over two takes or a
    /// clip with content).
    func setAnnotationAnchor(_ id: String, to choice: AnnotationCommands.AnchorChoice) {
        guard canEdit, !isGesturing, let document, let annotation = document.annotations.items.first(where: { $0.id == id }) else { return }
        var moved = annotation
        if let scene = shownScene, let instant = shownInstant(of: annotation, in: document) {
            let frame = scene.frame(at: Double(instant) / 1e9) { _ in true }
            if let drawn = DrawnAnnotation.all(in: frame).first(where: { $0.layer.id == id }) {
                let space: Rect? =
                    switch choice {
                    case .output, .whole:
                        AnnotationGeometry.outputSpace(outputSize: SIMD2(Double(frame.outputSize.x), Double(frame.outputSize.y)))
                    case .recording:
                        contentSpace(of: frame, atOutput: instant, in: document)
                    }
                if let space { moved = AnnotationInspectorRules.reanchored(annotation, from: drawn.space, to: space) }
            }
        }
        var ends: (from: NormalizedPoint, to: NormalizedPoint)?
        var target: NormalizedPoint?
        switch moved.kind {
        case let .arrow(arrow): ends = (arrow.from, arrow.to)
        case let .callout(callout): target = callout.target
        default: break
        }
        guard
            let anchored = AnnotationCommands.setAnchor(
                document, id: id, to: choice, rect: moved.rect, from: ends?.from, to: ends?.to, target: target)
        else {
            NSSound.beep()
            return
        }
        var changes = anchored.changes
        // Its sizes in the new space, in the same step: one undo takes both back.
        if moved.kind != annotation.kind, let after = try? document.applying(anchored.changes),
            let sized = AnnotationCommands.change(after, id: id, { $0.kind = moved.kind })
        {
            changes += sized.changes
        }
        perform(EditStep(label: anchored.label, target: anchored.target, changes: changes))
    }

    /// An output instant the output shows annotation `id` at: the playhead's if it does, otherwise the first frame of the
    /// grid once it is all in (its entrance over), inside its range. `nil` if the output never shows it.
    private func shownInstant(of annotation: Annotation, in document: EditDocument) -> Int64? {
        let map = TimeMap(sequence: document.sequence)
        let playhead = playheadNanoseconds
        if AnnotationTiming.state(of: annotation, atOutput: playhead, document: document, timeMap: map) != nil { return playhead }
        guard let output = TimelineAnnotationItems.range(of: annotation.id, in: document) else { return nil }
        let rate = document.frameRate
        let shown = output.lowerBound + min(AnnotationTiming.transition, (output.upperBound - output.lowerBound) / 2)
        var frame = Int((Double(shown) * Double(rate) / 1e9).rounded(.up))
        while Int64(TimeMap.frameTime(frame, frameRate: rate)) < shown { frame += 1 }
        let τ = Int64(TimeMap.frameTime(frame, frameRate: rate))
        return τ < output.upperBound ? τ : output.lowerBound
    }

    /// Image… and Clip… of the tab (design §5.4): the file chosen goes over the video at the playhead, centred
    /// (`addOverlay(from:at:)`); `importing` says its name while it is copied, and `nil` once done. One that cannot be
    /// added says so.
    func chooseOverlay(_ kind: ImportedFile, importing: @escaping @MainActor (String?) -> Void) {
        chooseFile(kind) { [weak self] url in
            guard let self else { return }
            importing(url.lastPathComponent)
            Task {
                let added = await self.addOverlay(from: url, at: nil)
                importing(nil)
                if !added {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "Couldn't add the file.")
                    if let window = self.window, window.isVisible {
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
    }
}
