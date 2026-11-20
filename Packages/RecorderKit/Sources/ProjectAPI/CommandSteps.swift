// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Darwin
import Editing
import Export
import Foundation
import ProjectFormat

/// What a command is worked out on: the document as it is, its project, and what the app's gesture reads besides (the
/// takes the sequence shows with their events, what each of them has, the recorded markers).
public struct CommandScope: Sendable {
    public var document: EditDocument
    public var project: LoadedProject
    /// The takes the sequence shows (`LoadedProject.takesShown(by:)`), with their events, in that order.
    public var takes: [(TakeRecord, [InputEvent])]
    /// `TakeTimeline.editableBounds` of each of `takes`, by take id: what the app's mix holds the sound's cuts to.
    public var takeBounds: [String: ClosedRange<HostTime>]
    /// The instants of the `marker` events of every take, by take id.
    public var recordedMarkers: MarkerList.Recorded
    public var makeID: @Sendable (String) -> String

    public init(
        document: EditDocument, project: LoadedProject, takes: [(TakeRecord, [InputEvent])],
        takeBounds: [String: ClosedRange<HostTime>], recordedMarkers: MarkerList.Recorded, makeID: @escaping @Sendable (String) -> String
    ) {
        self.document = document
        self.project = project
        self.takes = takes
        self.takeBounds = takeBounds
        self.recordedMarkers = recordedMarkers
        self.makeID = makeID
    }

    /// The scope of `document` in `project`, its takes' events read (from the disk, the first time): never call it on the
    /// main thread. An event log that cannot be read gives that take no events, as the app's editor reads it.
    public static func reading(
        project: LoadedProject, document: EditDocument, makeID: @escaping @Sendable (String) -> String
    ) throws -> CommandScope {
        let takes = project.takesShown(by: document).map { ($0.take, $0.events) }
        var bounds: [String: ClosedRange<HostTime>] = [:]
        for (take, events) in takes where bounds[take.id] == nil {
            let editable = TakeTimeline.editableBounds(take: take, events: events)
            bounds[take.id] = editable.start...editable.end
        }
        return CommandScope(
            document: document, project: project, takes: takes, takeBounds: bounds,
            recordedMarkers: recordedMarkers(of: project), makeID: makeID)
    }

    /// The instants of the `marker` events of every take of `project`, by take id, as the app's editor reads them
    /// (`EditorModel.recordedMarkers(of:)`); a take without any has none. Reads the disk the first time.
    public static func recordedMarkers(of project: LoadedProject) -> MarkerList.Recorded {
        var recorded: MarkerList.Recorded = [:]
        for take in [project.take] + project.takes where recorded[take.id] == nil {
            let instants = MarkerList.recordedInstants(in: project.events(ofTake: take.id))
            if !instants.isEmpty { recorded[take.id] = instants }
        }
        return recorded
    }

    var timeMap: TimeMap { TimeMap(sequence: document.sequence) }

    /// The markers the output shows, in output order.
    var visibleMarkers: [VisibleMarker] {
        MarkerList.visible(document: document, recorded: recordedMarkers, timeMap: timeMap)
    }
}

/// What a command comes to on the document as it is.
public enum CommandStep: Sendable {
    /// One step for `EditSession.perform`; `created` is the id of what it makes.
    case step(EditStep, created: String?)
    /// The project already is as the command asks (a setter given the value it has): nothing to do, and no error.
    case unchanged
    /// The command needs the session itself: `applyStyle` (its image comes into the package), `transcribe` and a
    /// `setBackground` with an image from outside the package (imported first).
    case needsSession
}

/// Each command as the step of the `*Commands` call the app's gesture makes (fases 4 y 5 design §6.2): the same step,
/// label and changes, so an edit of the API and one in the app are undone and logged alike. A command the app makes in
/// two gestures (plan 4b decision 4) is one step: the changes of the first and those of the second worked out on the
/// document the first leaves, with the first's label. Times are seconds of the output, checked first (plan 4b decision
/// 3): outside `[0, duration]`, not finite, or `from >= to` is `outOfRange`.
public enum CommandSteps {
    public static func step(for command: ProjectCommand, in scope: CommandScope) throws(APIError) -> CommandStep {
        let doc = scope.document
        let map = scope.timeMap
        let name = command.name
        switch command {
        case let .cut(from, to):
            return try delete(try range(from, to, map, name), in: scope)
        case let .trimStart(to):
            let end = try time(to, map, name, key: "to")
            guard end > 0 else { throw APIError(.outOfRange, "trimStart: to has to be after the start of the output") }
            return try delete(0..<end, in: scope)
        case let .trimEnd(from):
            let start = try time(from, map, name, key: "from")
            guard start < map.duration else { throw APIError(.outOfRange, "trimEnd: from has to be before the end of the output") }
            return try delete(start..<map.duration, in: scope)
        case let .setSpeed(from, to, speed):
            return try setSpeed(try range(from, to, map, name), speed: speed, in: scope)
        case .removeFillers:
            guard doc.transcript != nil else { throw noTranscript(name) }
            return try sequenceStep(TranscriptCommands.removeFillers(doc, takeBounds: scope.takeBounds, makeID: scope.makeID))
        case let .shortenPauses(longerThan):
            guard longerThan.isFinite, longerThan > 0 else {
                throw APIError(.outOfRange, "shortenPauses: longerThan is a number of seconds above 0")
            }
            guard doc.transcript != nil else { throw noTranscript(name) }
            let threshold = TimeMap.outputNanoseconds(seconds: longerThan)
            return try sequenceStep(
                TranscriptCommands.shortenPauses(doc, threshold: threshold, takeBounds: scope.takeBounds, makeID: scope.makeID))
        case let .addZoom(from, to, depth, focus):
            return try addZoom(try range(from, to, map, name), depth: depth, focus: focus, in: scope)
        case let .removeZoom(id):
            guard let step = ZoomCommands.delete(doc, ids: [id]) else {
                throw APIError(.refused, "there is no zoom block “\(id)”")
            }
            return .step(step, created: nil)
        case let .setAutoZoom(enabled, followsFocus):
            var settings = doc.zoom.auto
            settings.enabled = enabled
            if let followsFocus { settings.followsFocus = followsFocus }
            guard settings != doc.zoom.auto else { return .unchanged }
            let step = ZoomCommands.regenerate(doc, takes: scope.takes, settings: settings)
            return step.changes.isEmpty ? .unchanged : .step(step, created: nil)
        case let .addMarker(at, markerName):
            return try addMarker(at: try time(at, map, name, key: "at"), name: markerName, in: scope)
        case let .renameMarker(id, markerName):
            let marker = try visibleMarker(id, in: scope)
            guard let step = MarkerCommands.rename(doc, marker, to: markerName, makeID: scope.makeID) else { return .unchanged }
            return .step(step, created: nil)
        case let .removeMarker(id):
            let marker = try visibleMarker(id, in: scope)
            guard let step = MarkerCommands.delete(doc, marker, makeID: scope.makeID) else {
                throw APIError(.refused, "the marker “\(id)” cannot be deleted")
            }
            return .step(step, created: nil)
        case let .setAspect(aspect):
            return StyleCommands.setAspect(doc, aspect).map { .step($0, created: nil) } ?? .unchanged
        case let .setBackground(background):
            if case let .image(file) = background {
                if file.hasPrefix("/") { return .needsSession }
                try checkAsset(file, in: scope.project.package)
            }
            // The app's `setBackground(_:blur:)` without a blur: the one step of `StyleCommands.set`.
            return StyleCommands.set(doc, "/style/background", background, label: .background).map { .step($0, created: nil) }
                ?? .unchanged
        case .applyStyle, .transcribe:
            return .needsSession
        case let .setCameraLayout(kind, side):
            return try setCameraLayout(kind, side: side, in: doc)
        case let .addTitleCard(at, title, subtitle):
            return try addTitleCard(at: at, title: title, subtitle: subtitle, in: scope)
        case let .addText(from, to, text, x, y):
            return try addText(try range(from, to, map, name), text: text, x: x, y: y, in: scope)
        case let .addMusic(theme, volume):
            return try addMusic(theme: theme, volume: volume, in: scope)
        case .removeMusic:
            return removeMusic(doc)
        case let .setTitle(title):
            return InfoCommands.setTitle(doc, title).map { .step($0, created: nil) } ?? .unchanged
        case let .setSummary(summary):
            return InfoCommands.setSummary(doc, summary).map { .step($0, created: nil) } ?? .unchanged
        }
    }

    // MARK: - The sequence

    /// `SequenceCommands.deleteRange` of `output`, as ⌫ over a marked range does.
    private static func delete(_ output: Range<Int64>, in scope: CommandScope) throws(APIError) -> CommandStep {
        try sequenceStep(
            SequenceCommands.deleteRange(scope.document, output: output, takeBounds: scope.takeBounds, makeID: scope.makeID))
    }

    /// A step of the sequence: `nil` or no changes is nothing to do; `lastClip` is refused.
    private static func sequenceStep(_ result: Result<EditStep, SequenceError>?) throws(APIError) -> CommandStep {
        switch result {
        case nil: return .unchanged
        case .failure(.lastClip)?: throw APIError(.refused, "it would leave no clip: there has to be at least one")
        case let .success(step)?: return step.changes.isEmpty ? .unchanged : .step(step, created: nil)
        }
    }

    /// "Split" over the range (`SequenceCommands.split(range:)`, both edges), then the speed of the clips inside it
    /// (`SequenceCommands.setSpeed`), as one step labelled `speed`.
    private static func setSpeed(_ output: Range<Int64>, speed: Double, in scope: CommandScope) throws(APIError) -> CommandStep {
        guard speed.isFinite, SequenceCommands.speedRange.contains(speed) else {
            throw APIError(.outOfRange, "setSpeed: speed is from 0.25 to 16")
        }
        let doc = scope.document
        let split = SequenceCommands.split(doc, range: output, makeID: scope.makeID)
        let cut = try applied(split?.changes ?? [], to: doc)
        let map = TimeMap(sequence: cut.sequence)
        // The clips whose middle the range holds: those the split left inside it.
        let inside = cut.sequence.indices.filter { k in
            let start = map.clipOutputStarts[k]
            let end = k + 1 < cut.sequence.count ? map.clipOutputStarts[k + 1] : map.duration
            let middle = start + (end - start) / 2
            return output.contains(middle) && cut.sequence[k].content == nil
        }
        guard !inside.isEmpty else {
            throw APIError(.refused, "no clip there can change its speed: a title card, a frozen frame or an imported clip keeps its own")
        }
        let ids = Set(inside.map { cut.sequence[$0].id })
        guard let faster = SequenceCommands.setSpeed(cut, clipIDs: ids, speed: speed, takeBounds: scope.takeBounds) else {
            if inside.allSatisfy({ ClipSpeed.clamped(cut.sequence[$0].speed) == ClipSpeed.clamped(speed) }) { return .unchanged }
            throw APIError(.refused, "a clip would be shorter than a frame at that speed")
        }
        return .step(
            EditStep(label: .speed, target: faster.target, changes: (split?.changes ?? []) + faster.changes), created: nil)
    }

    // MARK: - Zoom

    /// "Add Zoom" over the range (`ZoomCommands.add`), then its card's depth and focus (`ZoomCommands.change`).
    private static func addZoom(
        _ output: Range<Int64>, depth: Double?, focus: CommandFocus?, in scope: CommandScope
    ) throws(APIError) -> CommandStep {
        if let depth, !(depth.isFinite && ZoomCommands.depthRange.contains(depth)) {
            throw APIError(.outOfRange, "addZoom: depth is from 1.25 to 4")
        }
        if case let .fixed(x, y)? = focus, !(x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)) {
            throw APIError(.outOfRange, "addZoom: a focus's x and y are from 0 to 1")
        }
        let doc = scope.document
        guard let add = ZoomCommands.add(doc, output: output, makeID: scope.makeID) else {
            throw APIError(.refused, "no zoom fits there: another block is in the way, or the free part lasts less than 0.3 s")
        }
        guard depth != nil || focus != nil else { return .step(add, created: add.target) }
        let zoomFocus = focus.map { focus -> ZoomFocus in
            switch focus {
            case .follow: .follow
            case let .fixed(x, y): .fixed(x: x, y: y)
            }
        }
        let after = try applied(add.changes, to: doc)
        let card = ZoomCommands.change(after, id: add.target, depth: depth.map { Optional.some($0) }, focus: zoomFocus)
        return .step(joined(add, card, label: .zoomAdd), created: add.target)
    }

    // MARK: - Markers

    /// "Add Marker" at `τ` (`MarkerCommands.add`), then its name (`MarkerCommands.rename`, as its flag does).
    private static func addMarker(at τ: Int64, name: String, in scope: CommandScope) throws(APIError) -> CommandStep {
        let doc = scope.document
        let map = scope.timeMap
        guard let add = MarkerCommands.add(doc, atOutput: τ, timeMap: map, recorded: scope.recordedMarkers, makeID: scope.makeID)
        else {
            if map.source(atOutput: τ) == nil { throw APIError(.refused, "the output shows nothing at that time") }
            throw APIError(.refused, "another marker is on that frame")
        }
        guard !MarkerCommands.normalized(name).isEmpty else { return .step(add, created: add.target) }
        let after = try applied(add.changes, to: doc)
        let shown = MarkerList.visible(document: after, recorded: scope.recordedMarkers, timeMap: TimeMap(sequence: after.sequence))
        let rename = shown.first { $0.id == add.target }.flatMap { MarkerCommands.rename(after, $0, to: name, makeID: scope.makeID) }
        return .step(joined(add, rename, label: .markerAdd), created: add.target)
    }

    /// The marker the output shows with the id `id`: an entry's, or `rec-<take>-<ns>` for a recorded one without one.
    private static func visibleMarker(_ id: String, in scope: CommandScope) throws(APIError) -> VisibleMarker {
        guard let marker = scope.visibleMarkers.first(where: { $0.id == id }) else {
            throw APIError(.refused, "the output shows no marker “\(id)”")
        }
        return marker
    }

    // MARK: - Style and camera

    /// An image of the package's `assets/`, as a background names one.
    private static func checkAsset(_ file: String, in package: ProjectPackage) throws(APIError) {
        guard DocumentRules.isAssetPath(file, as: .asset) else {
            throw APIError(
                .invalidCommand,
                "setBackground: an image's file is “assets/<name>” of the project, or the absolute path of an image to bring in")
        }
        var info = stat()
        guard lstat(package.url.appending(path: file).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw APIError(.refused, "the project has no image \(file)")
        }
    }

    /// The project's layout (`LayoutCommands.setProjectLayout`), then a split's side (`LayoutCommands.setSplit`).
    private static func setCameraLayout(_ kind: LayoutKind, side: CameraSide?, in doc: EditDocument) throws(APIError) -> CommandStep {
        if side != nil, kind != .split { throw APIError(.refused, "setCameraLayout: side is only for the split layout") }
        let layout = LayoutCommands.setProjectLayout(doc, kind)
        let after = try applied(layout?.changes ?? [], to: doc)
        let split = side.flatMap { LayoutCommands.setSplit(after, id: nil, side: $0) }
        switch (layout, split) {
        case (nil, nil): return .unchanged
        case let (layout?, split): return .step(joined(layout, split, label: .cameraLayout), created: nil)
        case let (nil, split?): return .step(split, created: nil)
        }
    }

    // MARK: - Content

    /// "Add Title Card" at `at` (`ContentClipCommands.addCard`, titled `title`), then its subtitle
    /// (`ContentClipCommands.changeCard`, as its inspector does).
    private static func addTitleCard(
        at: CommandPlace, title: String, subtitle: String?, in scope: CommandScope
    ) throws(APIError) -> CommandStep {
        let doc = scope.document
        let place: ContentClipCommands.Place
        switch at {
        case .start: place = .start
        case .end: place = .end
        case let .at(seconds): place = .output(try time(seconds, scope.timeMap, "addTitleCard", key: "at"))
        }
        guard let add = ContentClipCommands.addCard(doc, at: place, title: title, makeID: scope.makeID) else {
            throw APIError(.refused, "a title card cannot go there")
        }
        guard let subtitle, !subtitle.isEmpty else { return .step(add, created: add.target) }
        let after = try applied(add.changes, to: doc)
        let change = ContentClipCommands.changeCard(after, clipID: add.target) { $0.subtitle = subtitle }
        return .step(joined(add, change, label: .clipCard), created: add.target)
    }

    /// A text annotation (`AnnotationDefaults.kind(.text, text:)`, its place `AnnotationDefaults.rect`) centred at `x`, `y`
    /// of its space, over the range (`AnnotationCommands.add`).
    private static func addText(
        _ output: Range<Int64>, text: String, x: Double, y: Double, in scope: CommandScope
    ) throws(APIError) -> CommandStep {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw APIError(.outOfRange, "addText: x and y are from 0 to 1")
        }
        let kind = AnnotationDefaults.kind(.text, text: text)
        var rect = AnnotationDefaults.rect(for: kind, aspect: nil, spaceAspect: 16.0 / 9)
        rect.x = x - rect.width / 2
        rect.y = y - rect.height / 2
        guard let step = AnnotationCommands.add(
            scope.document, kind, atOutput: output.lowerBound, rect: rect, duration: output.upperBound - output.lowerBound,
            makeID: scope.makeID)
        else { throw APIError(.refused, "a text needs at least 0.3 s of output there") }
        return .step(step, created: step.target)
    }

    // MARK: - Music

    /// A theme of the library at the start of the output (`MusicCommands.add`), then its volume (`MusicCommands.change`).
    private static func addMusic(theme: String, volume: Double?, in scope: CommandScope) throws(APIError) -> CommandStep {
        guard MusicThemes.ids.contains(theme) else {
            throw APIError(.invalidCommand, "addMusic: theme is one of \(MusicThemes.ids.joined(separator: ", "))")
        }
        if let volume, !(volume.isFinite && MusicCommands.gains.contains(volume)) {
            throw APIError(.outOfRange, "addMusic: volume is in dB, from -120 to 6")
        }
        let doc = scope.document
        guard let add = MusicCommands.add(
            doc, source: MusicThemes.source(theme), atOutput: 0, timeMap: scope.timeMap, makeID: scope.makeID)
        else { throw APIError(.refused, "there is no room for music at the start: remove the music the project has first") }
        guard let volume else { return .step(add, created: add.target) }
        let after = try applied(add.changes, to: doc)
        let change = MusicCommands.change(after, id: add.target) { $0.gain = volume }
        return .step(joined(add, change, label: .musicAdd), created: add.target)
    }

    /// Every piece of music taken out (`MusicCommands.delete` of each, in order), as one step.
    private static func removeMusic(_ doc: EditDocument) -> CommandStep {
        var document = doc
        var changes: [EditChange] = []
        var ids: [String] = []
        for item in doc.music.items {
            guard let step = MusicCommands.delete(document, id: item.id), let next = try? document.applying(step.changes) else { break }
            changes += step.changes
            ids.append(item.id)
            document = next
        }
        guard !changes.isEmpty else { return .unchanged }
        return .step(EditStep(label: .musicDelete, target: ids.joined(separator: ","), changes: changes), created: nil)
    }

    // MARK: - Shared

    /// `first` and then `second` (worked out on the document `first` leaves), one step of `label` and `first`'s target.
    private static func joined(_ first: EditStep, _ second: EditStep?, label: EditLabel) -> EditStep {
        guard let second, !second.changes.isEmpty else { return first }
        return EditStep(label: label, target: first.target, changes: first.changes + second.changes)
    }

    private static func applied(_ changes: [EditChange], to doc: EditDocument) throws(APIError) -> EditDocument {
        guard !changes.isEmpty else { return doc }
        do { return try doc.applying(changes) } catch {
            throw APIError(.refused, "the change does not apply to the document")
        }
    }

    private static func noTranscript(_ command: String) -> APIError {
        APIError(.refused, "\(command): the project has no transcript; transcribe it first")
    }

    /// `seconds` of output in ns: `outOfRange` outside `[0, duration]` or not finite.
    static func time(_ seconds: Double, _ map: TimeMap, _ command: String, key: String) throws(APIError) -> Int64 {
        guard seconds.isFinite, seconds >= 0, seconds <= map.durationSeconds else {
            throw APIError(
                .outOfRange, "\(command): \(key) is a time in seconds from 0 to \(format(map.durationSeconds)), the length of the output")
        }
        return min(TimeMap.outputNanoseconds(seconds: seconds), map.duration)
    }

    /// The output range `[from, to)` in ns: `outOfRange` for a time out of the output or `from >= to`.
    static func range(_ from: Double, _ to: Double, _ map: TimeMap, _ command: String) throws(APIError) -> Range<Int64> {
        let start = try time(from, map, command, key: "from")
        let end = try time(to, map, command, key: "to")
        guard start < end else { throw APIError(.outOfRange, "\(command): from has to be before to") }
        return start..<end
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
