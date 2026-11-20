// SPDX-License-Identifier: GPL-3.0-or-later
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
        try await withApp { dir, environment, app in
            let url = try await APIFixtures.package(in: dir).package.url
            // Nobody holds the lock: nothing is asked of the app.
            _ = try await ProjectRunner.report(url, environment: environment)
            #expect(app.ops.isEmpty)

            let session = try await app.open(url)
            #expect(session.perform(try #require(InfoCommands.setTitle(session.document, "En la app"))) == .applied)
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
            #expect(app.ops == [.flush, .flush, .flush, .flush])
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
@MainActor private func withApp(_ body: (URL, APIEnvironment, TestApp) async throws -> Void) async throws {
    try await withTemporaryDirectory { dir in
        try await withShortDirectory { short in
            var environment = APIFixtures.environment(in: dir)
            environment.controlSocket = short.appending(path: "control.sock")
            let app = TestApp(environment: environment)
            try app.server.start()
            defer { app.server.stop() }
            try await body(dir, environment, app)
        }
    }
}
