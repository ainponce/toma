// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Darwin
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import ProjectAPI

/// The command line and the app on the same project (fases 4 y 5 design §6.4; plan 4b, Task A6, Review Focus 1): while
/// the app has a project open, and so its `edit.lock`, a change, an undo or a redo of `ProjectRunner` is made by the app
/// over its control socket, never by a second writer; reads and exports ask the app to flush first. The app is a test
/// one: edit sessions holding their locks, and a `ControlServer` that answers through `ControlHandling` with the session
/// of the package a request names, found by its identity as the app finds its editor.
@MainActor @Suite struct ProjectRunnerAppTests {
    @Test func lockedProjectGoesThroughTheApp() async throws {
        try await withApp { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await app.open(url)

            var told: [Int] = []
            let batch = await ProjectRunner.apply(
                [.addMarker(at: 2, name: "CLI"), .setTitle("Por la app")], to: url, environment: environment
            ) { k, _ in told.append(k) }
            #expect(batch.error == nil, "\(String(describing: batch.error))")
            #expect(batch.results.map(\.via) == [.app, .app])
            #expect(batch.results.map(\.command) == ["addMarker", "setTitle"])
            #expect(batch.results.first?.label == EditLabel.markerAdd.rawValue)
            #expect(told == [0, 1])
            // The app's document changed, as its own gestures change it: seen, and on the disk.
            #expect(session.document.markers.items.contains { $0.name == "CLI" })
            #expect(session.document.info?.title == "Por la app")
            #expect(!session.hasUnsavedChanges)
            #expect(app.ops == [.apply])
            let onDisk = try await TomaProject.open(url, mode: .read, environment: environment)
            #expect(onDisk.document.info?.title == "Por la app")
            await onDisk.close()

            // Its Edit ▸ Undo undoes them, one at a time.
            #expect(session.undoLabel == .projectTitle)
            #expect(session.undo() == .applied)
            #expect(session.document.info?.title != "Por la app")
            // And `toma undo` is the app's undo too.
            let undone = try await ProjectRunner.undo(url, environment: environment)
            #expect(undone.via == .app)
            #expect(undone.label == EditLabel.markerAdd.rawValue)
            #expect(!session.document.markers.items.contains { $0.name == "CLI" })
            let redone = try await ProjectRunner.redo(url, environment: environment)
            #expect(redone.via == .app && redone.label == EditLabel.markerAdd.rawValue)
            #expect(session.document.markers.items.contains { $0.name == "CLI" })

            // A list that stops: what ran stays, and says where it stopped.
            let stopped = await ProjectRunner.apply([.setAspect(.portrait), .cut(from: 4, to: 99)], to: url, environment: environment)
            #expect(stopped.results.count == 1)
            #expect(stopped.failedIndex == 1)
            #expect(stopped.error?.code == .outOfRange)
            #expect(session.document.aspect == .portrait)
            await app.close()
        }
    }

    @Test func notOpenInTheAppIsLocked() async throws {
        try await withApp { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            let other = try await APIFixtures.package(in: dir, name: "Other").package.url
            _ = try await app.open(other)
            // Another app (not the one answering) holds the project's lock.
            let elsewhere = try await EditSession.open(url, take: nil, context: environment.editContext)
            let before = try treeHash(url)
            let batch = await ProjectRunner.apply([.addMarker(at: 2, name: "CLI")], to: url, environment: environment)
            #expect(batch.error?.code == .locked)
            #expect(batch.results.isEmpty && batch.failedIndex == nil)
            let undo = await APIFixtures.apiError { _ = try await ProjectRunner.undo(url, environment: environment) }
            #expect(undo?.code == .locked)
            #expect(app.ops == [.apply, .undo])
            #expect(try treeHash(url) == before)
            #expect(!elsewhere.document.markers.items.contains { $0.name == "CLI" })
            await elsewhere.close()
            await app.close()
        }
    }

    @Test func noAppIsLocked() async throws {
        try await withTemporaryDirectory { dir in
            try await withShortDirectory { short in
                var environment = APIFixtures.environment(in: dir)
                environment.controlSocket = short.appending(path: "control.sock")
                let url = try await APIFixtures.package(in: dir).package.url
                let holder = try await EditSession.open(url, take: nil, context: environment.editContext)
                let batch = await ProjectRunner.apply([.addMarker(at: 2, name: "CLI")], to: url, environment: environment)
                #expect(batch.error?.code == .locked)
                #expect(batch.results.isEmpty)
                let redo = await APIFixtures.apiError { _ = try await ProjectRunner.redo(url, environment: environment) }
                #expect(redo?.code == .locked)
                // A socket a crash left, which nobody answers on: the same.
                let stale = socket(AF_UNIX, SOCK_STREAM, 0)
                var address = try #require(ControlWire.address(environment.controlSocket.path))
                _ = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                close(stale)
                let again = await ProjectRunner.apply([.addMarker(at: 2, name: "CLI")], to: url, environment: environment)
                #expect(again.error?.code == .locked)
                // Reads go on, from the disk.
                #expect(try await ProjectRunner.report(url, environment: environment).duration > 0)
                await holder.close()
            }
        }
    }

    @Test func samePackageByAnotherPathIsFound() async throws {
        try await withApp { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await app.open(url)
            // A link to the folder above the package: another path, the same folder.
            let above = dir.appending(path: "Above")
            try FileManager.default.createSymbolicLink(at: above, withDestinationURL: dir)
            let other = above.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
            let batch = await ProjectRunner.apply([.addMarker(at: 3.5, name: "Otra ruta")], to: other, environment: environment)
            #expect(batch.error == nil)
            #expect(batch.results.first?.via == .app)
            #expect(session.document.markers.items.contains { $0.name == "Otra ruta" })
            await app.close()
        }
    }

    @Test func readsAndExportsAskTheAppToFlushFirst() async throws {
        // The app's writes take 300 ms: without the flush, the read would find the title before the change.
        try await withApp(journalIO: SlowWrites(seconds: 0.3).io) { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            // An app that does not have the project answers at once, and the read goes on.
            _ = try await ProjectRunner.report(url, environment: environment)
            #expect(app.ops == [.flush])

            let session = try await app.open(url)
            #expect(session.perform(try #require(InfoCommands.setTitle(session.document, "En la app"))) == .applied)
            #expect(session.hasUnsavedChanges)
            let report = try await ProjectRunner.report(url, environment: environment)
            #expect(report.info?.title == "En la app")
            _ = try await ProjectRunner.markers(url, environment: environment)
            _ = try await ProjectRunner.transcript(url, environment: environment)
            // An export (refused for its codec, once the app flushed: nothing is exported).
            let export = await APIFixtures.apiError {
                _ = try await ProjectRunner.export(
                    url, to: dir.appending(path: "out.mp4"), request: ExportRequest(codec: "vp9"), environment: environment,
                    progress: nil)
            }
            #expect(export?.code == .invalidCommand)
            #expect(app.ops == [.flush, .flush, .flush, .flush, .flush])
            await app.close()
        }
    }

    @Test func transcribeThroughTheAppIsNotAvailable() async throws {
        try await withApp { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await app.open(url)
            let before = session.document
            let transcribe = await ProjectRunner.apply([.transcribe(language: "es-MX", replace: false)], to: url, environment: environment)
            #expect(transcribe.error?.code == .notAvailable)
            #expect(transcribe.failedIndex == 0)
            // An image from outside the package: never named through the socket.
            let image = dir.appending(path: "photo.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
            let background = await ProjectRunner.apply(
                [.setTitle("Antes"), .setBackground(.image(file: image.path))], to: url, environment: environment)
            #expect(background.error?.code == .notAvailable)
            #expect(background.results.count == 1 && background.failedIndex == 1)
            #expect(session.document.style == before.style)
            await app.close()
        }
    }

    @Test func styleThroughTheAppIsTheRowStyle() async throws {
        try await withApp { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await app.open(url)
            let missing = await ProjectRunner.apply([.applyStyle(id: "nope")], to: url, environment: environment)
            #expect(missing.error?.code == .refused)
            #expect(missing.error?.message.contains("toma") == true)
            #expect(session.undoLabel == nil)
            _ = await ProjectRunner.apply([.setAspect(.square)], to: url, environment: environment)
            let applied = await ProjectRunner.apply([.applyStyle(id: NamedStyle.tomaStyleID)], to: url, environment: environment)
            #expect(applied.error == nil)
            #expect(applied.results.first?.via == .app)
            await app.close()
        }
    }
}

extension ProjectRunnerAppTests {
    /// Review I1: the answer goes by the request's own line of the log. The user edits in the editor while the app waits
    /// for that line: it was saved, so it is no `refused` (an agent trying it again would cut twice).
    @Test func aSavedChangeIsNotRefusedWhileTheUserEdits() async throws {
        try await withTemporaryDirectory { dir in
            var environment = APIFixtures.environment(in: dir)
            environment.journalIO = SlowWrites(seconds: 0.3).io
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await EditSession.open(url, take: nil, context: environment.editContext)
            let edits = UserEdits()
            // As the step is handed over, the user changes the title in the editor: its line goes while the request's
            // is still being written.
            let editor = ControlEditor(
                session: session, project: { session.project }, takeBounds: { [:] }, canEdit: { session.access == .editable },
                perform: { step in
                    let outcome = session.perform(step, joiningBurst: false)
                    edits.soon(in: session)
                    return outcome
                },
                applyStyle: { await session.applyStyle($0, imageDirectory: $1).outcome }, stylesFolder: environment.stylesFolder,
                tomaStyleName: "Toma's Style", makeID: environment.makeID)
            let response = await ControlHandling.apply([.addMarker(at: 2, name: "CLI"), .setAspect(.square)], editor: editor)
            #expect(response.error == nil, "\(String(describing: response.error))")
            #expect(response.results.map(\.changed) == [true, true])
            #expect(edits.count == 2)
            // The undo too, while the user edits again.
            let undo = await ControlHandling.handle(ControlRequest(op: .undo, package: nil, commands: nil), editor: editor)
            #expect(undo.error == nil, "\(String(describing: undo.error))")
            edits.soon(in: session)
            let redo = await ControlHandling.handle(ControlRequest(op: .redo, package: nil, commands: nil), editor: editor)
            #expect(redo.error == nil, "\(String(describing: redo.error))")
            _ = await session.flushed()
            await session.close()
        }
    }

    /// The final review: through the app, as without it, every command is an undo of its own, also when the editor's
    /// bursts would join them (the same label and target within a second: here every step is at the same instant).
    @Test func eachCommandThroughTheAppIsAnUndoOfItsOwn() async throws {
        try await withApp(stoppedClock: true) { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await app.open(url)
            // The editor's own burst joins: two titles typed in a row are one undo.
            #expect(session.perform(try #require(InfoCommands.setTitle(session.document, "x"))) == .applied)
            #expect(session.perform(try #require(InfoCommands.setTitle(session.document, "xy"))) == .applied)
            #expect(session.undo() == .applied)
            #expect(session.document.info == nil)

            let titles = await ProjectRunner.apply(
                [.setTitle("a"), .setTitle("b"), .setTitle("c")], to: url, environment: environment)
            #expect(titles.error == nil && titles.results.allSatisfy { $0.via == .app })
            for expected in ["b", "a"] {
                #expect(session.undo() == .applied)
                #expect(session.document.info?.title == expected)
            }
            #expect(session.undo() == .applied)
            #expect(session.document.info == nil)

            // The review's case: cuts in a row on one clip.
            let cuts = await ProjectRunner.apply(
                [.cut(from: 1, to: 2), .cut(from: 1, to: 2), .cut(from: 1, to: 2)], to: url, environment: environment)
            #expect(cuts.error == nil)
            let seconds = { TimeMap(sequence: session.document.sequence).durationSeconds }
            #expect(abs(seconds() - 7) < 0.01)
            for expected in [8.0, 9.0, 10.0] {
                let undone = try await ProjectRunner.undo(url, environment: environment)
                #expect(undone.via == .app)
                #expect(abs(seconds() - expected) < 0.01, "\(seconds())")
            }
            await app.close()
        }
    }

    /// A step the disk refuses is still `refused`: its own line is not on the disk.
    @Test func aChangeTheDiskRefusesIsRefused() async throws {
        try await withTemporaryDirectory { dir in
            let failing = APIFixtures.FailingIO()
            var environment = APIFixtures.environment(in: dir)
            environment.journalIO = failing.io
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await EditSession.open(url, take: nil, context: environment.editContext)
            failing.failWrites(with: .ENOSPC)
            let editor = ControlEditor(session: session, stylesFolder: environment.stylesFolder, makeID: environment.makeID)
            let response = await ControlHandling.apply([.addMarker(at: 2, name: "CLI")], editor: editor)
            #expect(response.error?.code == .refused)
            #expect(response.error?.message.contains("could not save") == true)
            #expect(response.failedIndex == 0 && response.results.isEmpty)
            failing.failWrites(with: nil)
            _ = await session.flushed()
            await session.close()
        }
    }

    /// Review M5: during a drag in the editor, a request changes nothing and says to try again.
    @Test func aRequestDuringAGestureChangesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let session = try await EditSession.open(url, take: nil, context: environment.editContext)
            #expect(session.perform(try #require(InfoCommands.setTitle(session.document, "Antes"))) == .applied)
            let dragging = Dragging()
            let editor = ControlEditor(
                session: session, project: { session.project }, takeBounds: { [:] }, canEdit: { session.access == .editable },
                perform: { session.perform($0, joiningBurst: false) },
                applyStyle: { await session.applyStyle($0, imageDirectory: $1, joiningBurst: false).outcome },
                stylesFolder: environment.stylesFolder, tomaStyleName: "Toma's Style", makeID: environment.makeID,
                isGesturing: { dragging.on })
            dragging.on = true
            let before = session.document, revision = session.revision
            let response = await ControlHandling.apply([.addMarker(at: 2, name: "CLI")], editor: editor)
            #expect(response.handled)
            #expect(response.error?.code == .refused)
            #expect(response.error?.message.contains("try again") == true)
            #expect(response.failedIndex == 0)
            for op in [ControlRequest.Op.undo, .redo] {
                let stepped = await ControlHandling.handle(ControlRequest(op: op, package: nil, commands: nil), editor: editor)
                #expect(op == .redo || stepped.error?.message.contains("try again") == true)
            }
            #expect(session.document == before && session.revision == revision)
            // Once the drag ends, the same request goes.
            dragging.on = false
            let after = await ControlHandling.apply([.addMarker(at: 2, name: "CLI")], editor: editor)
            #expect(after.error == nil)
            _ = await session.flushed()
            await session.close()
        }
    }

    /// Review M8: an app that is there but does not answer as it should is `refused`, with what to do; `locked` is only
    /// for nothing asked or nothing done.
    @Test func anAppThatDoesNotAnswerIsRefusedNotLocked() async throws {
        try await withTemporaryDirectory { dir in
            try await withShortDirectory { short in
                var environment = APIFixtures.environment(in: dir)
                environment.controlSocket = short.appending(path: "control.sock")
                let url = try await APIFixtures.package(in: dir).package.url
                let holder = try await EditSession.open(url, take: nil, context: environment.editContext)
                // It closes every connection unanswered.
                let server = ControlServer(path: environment.controlSocket, peerCheck: { _ in false }) { _ in .done }
                try server.start()
                defer { server.stop() }
                let batch = await ProjectRunner.apply([.addMarker(at: 2, name: "CLI")], to: url, environment: environment)
                #expect(batch.error?.code == .refused)
                #expect(batch.error?.message.contains("read the project") == true)
                let undo = await APIFixtures.apiError { _ = try await ProjectRunner.undo(url, environment: environment) }
                #expect(undo?.code == .refused)
                await holder.close()
            }
        }
    }
}

/// The user's edits in the editor, made a moment after they are asked for.
@MainActor private final class UserEdits {
    private(set) var count = 0

    /// In 30 ms, the title changes.
    func soon(in session: EditSession) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            count += 1
            if let step = InfoCommands.setTitle(session.document, "Del usuario \(count)") { _ = session.perform(step) }
        }
    }
}

@MainActor private final class Dragging {
    var on = false
}

/// The journal's calls to the disk, each write taking `seconds` first.
final class SlowWrites: Sendable {
    let seconds: Double

    init(seconds: Double) {
        self.seconds = seconds
    }

    var io: EditJournalIO {
        let seconds = seconds
        return EditJournalIO(
            open: { try EditJournalIO.system.open($0, $1, $2) },
            write: { descriptor, bytes in
                Thread.sleep(forTimeInterval: seconds)
                return try EditJournalIO.system.write(descriptor, bytes)
            },
            fullSync: { try EditJournalIO.system.fullSync($0) },
            fsync: { try EditJournalIO.system.fsync($0) },
            syncDirectory: { try EditJournalIO.system.syncDirectory($0) })
    }
}

// MARK: - The app of the tests

/// A test app: edit sessions holding their packages' locks, answered for over a control socket at a short path as the app
/// answers (`ControlHandling`), each request's op noted.
@MainActor private final class TestApp {
    let server: ControlServer
    let environment: APIEnvironment
    private let shared: Shared

    /// The sessions the app has open, which the server's handler looks in, and the ops it was asked.
    final class Shared: Sendable {
        private let sessions = Mutex<[EditSession]>([])
        private let seen = Mutex<[ControlRequest.Op]>([])
        var all: [EditSession] { sessions.withLock { $0 } }
        var ops: [ControlRequest.Op] { seen.withLock { $0 } }
        func add(_ session: EditSession) { sessions.withLock { $0.append(session) } }
        func note(_ op: ControlRequest.Op) { seen.withLock { $0.append(op) } }
    }

    init(environment: APIEnvironment) {
        let shared = Shared()
        let stylesFolder = environment.stylesFolder, makeID = environment.makeID
        self.environment = environment
        self.shared = shared
        server = ControlServer(path: environment.controlSocket) { request in
            shared.note(request.op)
            return await TestApp.answer(request, shared: shared, stylesFolder: stylesFolder, makeID: makeID)
        }
    }

    var ops: [ControlRequest.Op] { shared.ops }

    /// The app opens the project at `url` in its editor: it holds its lock.
    func open(_ url: URL) async throws -> EditSession {
        let session = try await EditSession.open(url, take: nil, context: environment.editContext)
        #expect(session.access == .editable)
        shared.add(session)
        return session
    }

    func close() async {
        server.stop()
        for session in shared.all { await session.close() }
    }

    private static func answer(
        _ request: ControlRequest, shared: Shared, stylesFolder: URL, makeID: @escaping @Sendable (String) -> String
    ) async -> ControlResponse {
        if request.op == .ping { return .done }
        guard let id = try? ControlHandling.packageID(request.package),
              let session = shared.all.first(where: { ControlPackageID(url: $0.packageURL) == id && $0.access == .editable })
        else { return .notHandled }
        return await ControlHandling.handle(request, editor: ControlEditor(session: session, stylesFolder: stylesFolder, makeID: makeID))
    }
}

/// `body` with a temporary folder, the API's environment of it with its control socket at a short path, and a test app
/// listening there.
@MainActor private func withApp(
    journalIO: EditJournalIO = .system, stoppedClock: Bool = false, _ body: (URL, APIEnvironment, TestApp) async throws -> Void
) async throws {
    try await withTemporaryDirectory { dir in
        try await withShortDirectory { short in
            var environment = APIFixtures.environment(in: dir, journalIO: journalIO, stoppedClock: stoppedClock)
            environment.controlSocket = short.appending(path: "control.sock")
            let app = TestApp(environment: environment)
            try app.server.start()
            defer { app.server.stop() }
            try await body(dir, environment, app)
        }
    }
}
