// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The commands of the Camera and Screen tracks and of the Camera tab (design §5.3 to §5.5 and §8.7), as pure functions
/// of the document. Each one gives the step that does it (`EditStep`), or `nil` when there is nothing to do;
/// `followCursor`, which always plans, gives a step without changes then.
///
/// - A change is kept at a source instant of its take, and edited at an output instant through the document's
///   `timeMap`: the source instant shown there (`TimeMap.source(atOutput:)`), of the take of the clip shown.
/// - The camera style that rules at an instant is its take's initial one or that of its last change at or before the
///   instant (`camera.changes` by `t`, the later in the list at one instant), as the render shows it (`CameraBubble`).
/// - Touching a change (its style, its instant, a screen boundary, the screen of a stretch) makes it the user's: a camera
///   change `origin: .user`, which the take never recorded, and a screen change `origin: .user`, which `followCursor`
///   keeps.
/// - The `target` of a step, which joins a burst of steps into one undo group, is the id of the change it acts on, or the
///   pointer of what it sets.
public enum TrackCommands {
    /// The sizes of the camera in the document: 0.10 to 0.45 of the output's height.
    static let cameraSizes: ClosedRange<Double> = 0.10...0.45

    // MARK: - The camera

    /// "Show Camera" (design §5.4).
    public static func setCameraShow(_ doc: EditDocument, _ show: Bool) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["camera", "show"], from: doc.camera.show, to: show)
        return changes.step(label: .camera, target: "/camera/show")
    }

    /// The camera style that rules at output instant `atOutput`: of the last change of the take shown there whose `t` is
    /// at or before the source instant shown, with its id; without one, the take's initial style (`CameraStyle.default`
    /// if it has none) and `nil`.
    public static func rulingCameraStyle(_ doc: EditDocument, atOutput: Int64, timeMap: TimeMap) -> (changeID: String?, style: CameraStyle) {
        guard let shown = shownInstant(doc, atOutput, timeMap) else {
            return (nil, doc.sequence.first.flatMap { doc.camera.initial[$0.take] } ?? .default)
        }
        return rulingCameraStyle(doc, take: shown.take, atSource: shown.source)
    }

    /// The camera style that rules the bubble of take `take` at its source instant `t`: of the take's last change whose
    /// `t` is at or before it, with its id; without one, the take's initial style (`CameraStyle.default` if it has none)
    /// and `nil`.
    static func rulingCameraStyle(_ doc: EditDocument, take: String, atSource t: HostTime) -> (changeID: String?, style: CameraStyle) {
        if let k = rulingChange(doc, take: take, at: t) { return (doc.camera.changes[k].id, doc.camera.changes[k].style) }
        return (nil, doc.camera.initial[take] ?? .default)
    }

    /// Edits the style that rules at output instant `atOutput` (`rulingCameraStyle`): the take's initial one, or that change,
    /// which is the user's then. The size is kept in `cameraSizes`. `nil` if that is the style there already, if nothing is
    /// shown there or the size is not a number.
    public static func setCameraStyle(_ doc: EditDocument, atOutput: Int64, timeMap: TimeMap, _ style: CameraStyle) -> EditStep? {
        guard !style.size.isNaN, let shown = shownInstant(doc, atOutput, timeMap) else { return nil }
        var style = style
        style.size = min(max(style.size, cameraSizes.lowerBound), cameraSizes.upperBound)
        var changes = DocumentChanges()
        if let k = rulingChange(doc, take: shown.take, at: shown.source) {
            let old = doc.camera.changes[k]
            guard old.style != style else { return nil }
            var new = old
            new.style = style
            new.origin = .user
            changes.replace(old, with: new, in: .cameraChanges, id: old.id)
            return changes.step(label: .camera, target: old.id)
        }
        if let initial = doc.camera.initial[shown.take] {
            changes.set(["camera", "initial", shown.take], from: initial, to: style)
        } else {
            // A take without an initial style gets one with its parent: a `set` cannot add a key.
            var initial = doc.camera.initial
            initial[shown.take] = style
            changes.set(["camera", "initial"], from: doc.camera.initial, to: initial)
        }
        return changes.step(label: .camera, target: JSONPointer(components: ["camera", "initial", shown.take]).string)
    }

    /// "Add a Change at the Playhead" (design §5.4): a change of the user's at the source instant shown at output instant
    /// `atOutput`, with the id `makeID("k-")` and the style that rules there, after the take's changes at earlier instants.
    /// `nil` if nothing is shown there, or the take has a change at that instant already.
    public static func addCameraChange(_ doc: EditDocument, atOutput: Int64, timeMap: TimeMap, makeID: (String) -> String) -> EditStep? {
        guard let shown = shownInstant(doc, atOutput, timeMap),
            !doc.camera.changes.contains(where: { $0.take == shown.take && $0.t == shown.source })
        else { return nil }
        var ids = Set(doc.camera.changes.map(\.id))
        let change = CameraChange(
            id: DocumentIDs.new("k-", makeID, avoiding: &ids), take: shown.take, t: shown.source,
            style: rulingCameraStyle(doc, atOutput: atOutput, timeMap: timeMap).style, origin: .user)
        let index = doc.camera.changes.firstIndex { $0.take == shown.take && $0.t > shown.source } ?? doc.camera.changes.count
        var changes = DocumentChanges()
        changes.insert(change, into: .cameraChanges, at: index)
        return changes.step(label: .camera, target: change.id)
    }

    /// "Delete Change" (design §5.4): the change before it, or the initial style, rules from then on. `nil` without it.
    public static func deleteCameraChange(_ doc: EditDocument, id: String) -> EditStep? {
        guard let k = doc.camera.changes.firstIndex(where: { $0.id == id }) else { return nil }
        var changes = DocumentChanges()
        changes.remove(doc.camera.changes[k], from: .cameraChanges, at: k)
        return changes.step(label: .camera, target: id)
    }

    /// Drags change `id` to the source instant shown at output instant `toOutput`, which is the user's then. `nil` if it is
    /// there already, if there is no such change, if that instant is not of its take, or if another change of the take is
    /// at it.
    public static func moveCameraChange(_ doc: EditDocument, id: String, toOutput: Int64, timeMap: TimeMap) -> EditStep? {
        guard let k = doc.camera.changes.firstIndex(where: { $0.id == id }), let shown = shownInstant(doc, toOutput, timeMap)
        else { return nil }
        let old = doc.camera.changes[k]
        guard shown.take == old.take, shown.source != old.t,
            !doc.camera.changes.contains(where: { $0.take == old.take && $0.t == shown.source })
        else { return nil }
        var new = old
        new.t = shown.source
        new.origin = .user
        var changes = DocumentChanges()
        changes.replace(old, with: new, in: .cameraChanges, id: id)
        return changes.step(label: .camera, target: id)
    }

    // MARK: - The screens

    /// Drags the boundary of screen change `changeID` to the source instant shown at output instant `toOutput`, which is
    /// the user's then: it stops 1 ns after the take's change before it and 1 ns before the one after it, so the screens
    /// keep their order. `nil` if it stays where it is, if there is no such change, or that instant is not of its take.
    public static func moveScreenBoundary(_ doc: EditDocument, changeID: String, toOutput: Int64, timeMap: TimeMap) -> EditStep? {
        guard let k = doc.screens.changes.firstIndex(where: { $0.id == changeID }), let shown = shownInstant(doc, toOutput, timeMap)
        else { return nil }
        let old = doc.screens.changes[k]
        guard shown.take == old.take else { return nil }
        let others = doc.screens.changes.indices.filter { $0 != k && doc.screens.changes[$0].take == old.take }.map { doc.screens.changes[$0].t }
        var t = shown.source
        if let before = others.filter({ $0 < old.t }).max() { t = max(t, HostTime(nanoseconds: before.nanoseconds + 1)) }
        if let after = others.filter({ $0 > old.t }).min() { t = min(t, HostTime(nanoseconds: after.nanoseconds - 1)) }
        guard t != old.t else { return nil }
        var new = old
        new.t = t
        new.origin = .user
        var changes = DocumentChanges()
        changes.replace(old, with: new, in: .screenChanges, id: changeID)
        return changes.step(label: .screen, target: changeID)
    }

    /// "Show «name»" (design §5.5): screen track `track` for the output range `forOutput` (clamped to the output), and from
    /// its end on what was shown there before, in the source of the take shown at its start (a range that ends in another
    /// take ends with this one's last instant shown):
    /// - the take's changes inside the range go;
    /// - at its start, a change of the user's to `track`, unless what is shown just before it is `track` already (a stretch
    ///   from the take's first instant gets one too: the initial screen stays the planner's); a change at that instant
    ///   already is the one kept, with its id;
    /// - at its end, a change of the user's back to what was shown there, unless that is `track`, or a change is at that
    ///   instant already: those go if they switch to `track`, which changes nothing any more.
    ///
    /// New changes have ids of `makeID("p-")` and go before the take's first change after their instant. `nil` if nothing
    /// changes (`track` is what the range shows already), or nothing is shown.
    public static func showScreen(
        _ doc: EditDocument, track: String, forOutput: Range<Int64>, timeMap: TimeMap, makeID: (String) -> String
    ) -> EditStep? {
        let lower = max(forOutput.lowerBound, 0), upper = min(forOutput.upperBound, timeMap.duration)
        guard lower < upper, let start = shownInstant(doc, lower, timeMap), let last = shownInstant(doc, upper - 1, timeMap),
            last.take == start.take
        else { return nil }
        let take = start.take, old = doc.screens.changes
        // Where what was shown before goes on, if it is shown.
        let resumes = upper < timeMap.duration ? shownInstant(doc, upper, timeMap).flatMap { $0.take == take ? $0.source : nil } : nil
        let end = resumes ?? HostTime(nanoseconds: last.source.nanoseconds + 1)
        /// The take's screen from source instant `t` on (`orAt`), or just before it, by the original changes.
        func screen(at t: HostTime, orAt: Bool) -> String? {
            let ruling = old.indices.filter { old[$0].take == take && (orAt ? old[$0].t <= t : old[$0].t < t) }
                .max { (old[$0].t, $0) < (old[$1].t, $1) }
            return ruling.map { old[$0].track } ?? doc.screens.initial[take]
        }
        let before = screen(at: start.source, orAt: false)
        let atStart = old.lastIndex { $0.take == take && $0.t == start.source }
        let atEnd = old.indices.filter { old[$0].take == take && old[$0].t == end }
        // A change at the end that switches to `track` changes nothing any more: those at that instant go with it.
        let endIsTrack = atEnd.last.map { old[$0].track == track } ?? false

        var ids = Set(old.map(\.id))
        var new: [ScreenChange] = []
        var target: String?
        for (k, change) in old.enumerated() {
            if change.take == take, change.t >= start.source, change.t < end {
                guard k == atStart, before != track else { continue }
                var kept = change
                if kept.track != track { (kept.track, kept.origin) = (track, .user) }
                new.append(kept)
                target = kept.id
            } else if !(endIsTrack && atEnd.contains(k)) {
                new.append(change)
            }
        }
        /// Inserts `change` before the take's first change after its instant.
        func place(_ change: ScreenChange) {
            new.insert(change, at: new.firstIndex { $0.take == take && $0.t > change.t } ?? new.count)
        }
        if before != track, atStart == nil {
            let id = DocumentIDs.new("p-", makeID, avoiding: &ids)
            place(ScreenChange(id: id, take: take, t: start.source, track: track, origin: .user))
            target = id
        }
        if resumes != nil, atEnd.isEmpty, let after = screen(at: end, orAt: true), after != track {
            let id = DocumentIDs.new("p-", makeID, avoiding: &ids)
            place(ScreenChange(id: id, take: take, t: end, track: after, origin: .user))
            target = target ?? id
        }
        var changes = DocumentChanges()
        changes.edit(.screenChanges, from: old, to: new, id: \.id)
        return changes.step(label: .screen, target: target ?? "/screens/changes")
    }

    /// "Follow the Cursor" (design §5.5 and §8.7): the take's automatic screen changes planned again by
    /// `ScreenFollowPlanner` in the document's output (its cuts and speeds), with the planner's initial screen, around the
    /// user's changes: those stay, an automatic one at the instant of one of them goes, and so does one that would switch
    /// to the screen shown already. With two or more screen tracks, the plan is named after its planner
    /// (`screens.planner`). One `set` of `/screens`, since the planner's name is an optional key; without anything to
    /// change, the step has no changes.
    public static func followCursor(_ doc: EditDocument, project: LoadedProject) -> EditStep {
        let take = project.take
        let timeMap = TimeMap(sequence: doc.sequence)
        let plan = ScreenFollowPlanner.plan(take: take, events: project.events, package: project.package, timeMap: timeMap)
        let follows = take.tracks.filter(\.kind.isScreen).count >= 2

        var screens = doc.screens
        if let initial = plan.initial { screens.initial[take.id] = initial }
        let users = doc.screens.changes.filter { $0.take == take.id && $0.origin == .user }
        let userIDs = Set(users.map(\.id)), userInstants = Set(users.map(\.t))
        let autos = (follows ? plan.changes : []).filter { !userIDs.contains($0.id) && !userInstants.contains($0.t) }
        var shown = screens.initial[take.id]
        var merged: [ScreenChange] = []
        for change in (users + autos).enumerated().sorted(by: { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }).map(\.element) {
            if change.origin == .auto, change.track == shown { continue }
            merged.append(change)
            shown = change.track
        }
        screens.changes = doc.screens.changes.filter { $0.take != take.id } + merged
        if follows { screens.planner = ScreenFollowPlanner.id }

        var changes = DocumentChanges()
        changes.set(["screens"], from: doc.screens, to: screens)
        return changes.stepEvenIfEmpty(label: .screen, target: "/screens")
    }

    // MARK: - Private

    /// The take and the source instant shown at output instant `τ`; `nil` for an output of 0 ns.
    private static func shownInstant(_ doc: EditDocument, _ τ: Int64, _ timeMap: TimeMap) -> (take: String, source: HostTime)? {
        guard let shown = timeMap.source(atOutput: τ), doc.sequence.indices.contains(shown.clip) else { return nil }
        return (doc.sequence[shown.clip].take, shown.source)
    }

    /// The index in `camera.changes` of the change of `take` that rules at source instant `t`: the last at or before it,
    /// the later in the list at one instant.
    private static func rulingChange(_ doc: EditDocument, take: String, at t: HostTime) -> Int? {
        doc.camera.changes.indices.filter { doc.camera.changes[$0].take == take && doc.camera.changes[$0].t <= t }
            .max { (doc.camera.changes[$0].t, $0) < (doc.camera.changes[$1].t, $1) }
    }
}
