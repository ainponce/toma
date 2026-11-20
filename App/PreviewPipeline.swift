// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Dispatch
import Export
import ProjectFormat
import Render
import Synchronization

// The editor's helpers that work off the main thread for `EditorModel`: the scene and the mix of each revision, the
// spans of video that could not be read, and the export's progress.

/// Builds the scene (`SequencePaths` and `FrameRenderer.makeScene`) and the mix of each revision of the document off the
/// main thread (design §7.8), one at a time: a revision asked for while one is being built waits, and only the latest
/// waiting one is built. The motion paths of each take of the last revision are kept for the next one when it changes
/// nothing they read (`MotionPaths.areThePaths(of:)`: a background, a shadow, the corners), which then costs no rebuild.
final class RevisionBuilder: Sendable {
    struct Built: Sendable {
        var ticket: PreviewBuilds.Ticket
        var document: EditDocument
        /// At the export's size.
        var scene: FrameEvaluator
        /// The revision's mix, if the project's was made.
        var mix: EditedMix?
        /// What the mix was made from when it is not `document`: the document with the solo (phase 3 design §7.2).
        var mixDocument: EditDocument?
    }

    private struct Request: Sendable {
        var ticket: PreviewBuilds.Ticket
        var document: EditDocument
        var outputSize: SIMD2<Int>
        var mix: EditedMix?
        var analysis: AnalysisInputs
        /// What the mix hears, `nil` for `document`: the document with the solo (`AudioSolo.applied(to:takes:)`), which only
        /// the preview's mix hears.
        var mixDocument: EditDocument?
    }

    private let renderer: FrameRenderer
    /// The project the renderer draws: the takes the paths are of.
    private let project: LoadedProject
    private let built: @MainActor @Sendable (Built) -> Void
    private let queue = DispatchQueue(label: "dev.toma.Editor.revisions", qos: .userInitiated)
    private let state = Mutex(State())

    private struct State {
        var pending: Request?
        var building = false
        /// The paths last built; used on `queue` only.
        var paths: SequencePaths?
    }

    /// `paths`: those of the revision shown (`FrameEvaluator.sequencePaths`). `built` is called on the main actor with
    /// each revision built.
    init(
        renderer: FrameRenderer, project: LoadedProject, paths: SequencePaths,
        built: @escaping @MainActor @Sendable (Built) -> Void
    ) {
        self.renderer = renderer
        self.project = project
        self.built = built
        state.withLock { $0.paths = paths }
    }

    /// Builds the request of `ticket`, `document` at `outputSize`, and its mix from `mix` (the project's) with
    /// `mixDocument` (`nil`: `document`); the scene reads `analysis` of the caches.
    func build(
        ticket: PreviewBuilds.Ticket, document: EditDocument, outputSize: SIMD2<Int>, mix: EditedMix?,
        analysis: AnalysisInputs, mixDocument: EditDocument? = nil
    ) {
        let start = state.withLock { state in
            state.pending = Request(
                ticket: ticket, document: document, outputSize: outputSize, mix: mix, analysis: analysis, mixDocument: mixDocument)
            defer { state.building = true }
            return !state.building
        }
        if start { queue.async { self.drain() } }
    }

    /// The paths of `document`: of each take, those last built if they are its, otherwise new ones. On `queue`.
    private func paths(of document: EditDocument) -> SequencePaths {
        let last = state.withLock { $0.paths }
        if let last, last.areThePaths(of: document) { return last }
        let paths = SequencePaths(
            project: project, document: document, cameraReadable: renderer.cameraReadableByTake, reusing: last)
        state.withLock { $0.paths = paths }
        return paths
    }

    private func drain() {
        while let request = state.withLock({ state -> Request? in
            guard let request = state.pending else {
                state.building = false
                return nil
            }
            state.pending = nil
            return request
        }) {
            let paths = paths(of: request.document)
            let result = Built(
                ticket: request.ticket, document: request.document,
                scene: renderer.makeScene(
                    document: request.document, paths: paths, outputSize: request.outputSize, analysis: request.analysis),
                mix: request.mix?.with(document: request.mixDocument ?? request.document, framesPerSecond: request.document.frameRate),
                mixDocument: request.mixDocument)
            let built = self.built
            Task { @MainActor in built(result) }
        }
    }
}

/// The spans of video the renderer could not read so far (`FrameRenderer.missingVideo`), read off the main thread (a
/// reader's lock is held while it decodes) after the frames the engine presents, one reading at a time.
final class MissingVideoCheck: Sendable {
    private let renderer: FrameRenderer
    private let found: @MainActor @Sendable ([ClosedRange<Double>]) -> Void
    private let queue = DispatchQueue(label: "dev.toma.Editor.missingVideo", qos: .utility)
    private let state = Mutex<(running: Bool, again: Bool, last: [ClosedRange<Double>])>((false, false, []))

    init(renderer: FrameRenderer, found: @escaping @MainActor @Sendable ([ClosedRange<Double>]) -> Void) {
        self.renderer = renderer
        self.found = found
    }

    /// Reads them again, from any thread; told on the main actor when they changed.
    func run() {
        let start = state.withLock { state in
            if state.running {
                state.again = true
                return false
            }
            state.running = true
            return true
        }
        if start { queue.async { self.read() } }
    }

    private func read() {
        while true {
            let spans = renderer.missingVideo.map { $0.start...$0.end }
            let changed = state.withLock { state in
                defer { state.last = spans }
                return state.last != spans
            }
            if changed {
                let found = self.found
                Task { @MainActor in found(spans) }
            }
            let again = state.withLock { state in
                defer { state.again = false }
                if !state.again { state.running = false }
                return state.again
            }
            if !again { return }
        }
    }
}

/// Lets export progress through at most every half percent, so the main thread is not called per frame.
final class ProgressThrottle: Sendable {
    private let last = Mutex(-1.0)

    func shouldReport(_ value: Double) -> Bool {
        last.withLock { last in
            guard value >= 1 || value - last >= 0.005 else { return false }
            last = value
            return true
        }
    }
}
