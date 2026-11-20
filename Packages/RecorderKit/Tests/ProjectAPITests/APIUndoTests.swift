// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Editing
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// Applying, undoing and redoing through the edit log (plan 4b decision 6).

@MainActor @Test func applyUndoRedo() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        let applied = try await project.apply(.setTitle("Demo"))
        #expect(applied == CommandResult(
            command: "setTitle", changed: true, label: "project.title", created: nil, duration: applied.duration,
            undo: "project.title", via: .project))
        #expect(project.document.info?.title == "Demo")
        let undone = try await project.undo()
        #expect(undone.command == "undo" && undone.changed && undone.label == "project.title")
        #expect(undone.undo == "transcript.create")
        #expect(project.document.info == nil)
        let redone = try await project.redo()
        #expect(redone.label == "project.title" && redone.undo == "project.title")
        #expect(project.document.info?.title == "Demo")
        #expect(await APIFixtures.apiError { _ = try await project.redo() }?.code == .refused)
        // Unchanged is no step: nothing new to undo.
        let same = try await project.apply(.setTitle("Demo"))
        #expect(!same.changed && same.label == nil && same.undo == "project.title")
        await project.close()
    }
}

@MainActor @Test func undoAcrossProcessesUsesTheLog() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let first = try await TomaProject.open(url, mode: .edit, environment: environment)
        let added = try await first.apply(.addMarker(at: 5, name: "Medio"))
        let id = try #require(added.created)
        await first.close()

        let second = try await TomaProject.open(url, mode: .edit, environment: environment)
        #expect(second.document.markers.items.contains { $0.id == id })
        let undone = try await second.undo()
        #expect(undone.label == "marker.add")
        #expect(!second.document.markers.items.contains { $0.id == id })
        await second.close()
        let reader = try await TomaProject.open(url, mode: .read, environment: environment)
        #expect(!reader.document.markers.items.contains { $0.id == id })
        await reader.close()
    }
}

@MainActor @Test func readModeRefusesEdits() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let before = try treeHash(url)
        let project = try await TomaProject.open(url, mode: .read, environment: environment)
        #expect(await APIFixtures.apiError { _ = try await project.apply(.setTitle("No")) }?.code == .refused)
        #expect(await APIFixtures.apiError { _ = try await project.undo() }?.code == .refused)
        #expect(await APIFixtures.apiError { _ = try await project.redo() }?.code == .refused)
        let batch = await project.apply([.setTitle("No")])
        #expect(batch.results.isEmpty && batch.failedIndex == 0 && batch.error?.code == .refused)
        await project.close()
        #expect(try treeHash(url) == before)
    }
}

@MainActor @Test func batchStopsAtTheFirstErrorAndKeepsWhatWasDone() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        let batch = await project.apply([.setTitle("Uno"), .cut(from: 20, to: 30), .setSummary("Tres")])
        #expect(batch.results.map(\.command) == ["setTitle"])
        #expect(batch.failedIndex == 1)
        #expect(batch.error?.code == .outOfRange)
        #expect(project.document.info == ProjectInfo(title: "Uno", summary: ""))
        await project.close()
        // What was done is on disk.
        let reader = try await TomaProject.open(url, mode: .read, environment: environment)
        #expect(reader.document.info?.title == "Uno")
        await reader.close()
    }
}

@MainActor @Test func eachCommandOfABatchIsItsOwnUndoStep() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        let original = project.document
        let batch = await project.apply([.setTitle("Uno"), .setAspect(.square), .addMarker(at: 5, name: "Medio")])
        #expect(batch.error == nil && batch.failedIndex == nil)
        #expect(batch.results.map(\.label) == ["project.title", "aspect", "marker.add"])
        var labels: [String?] = []
        for _ in 0..<3 { labels.append(try await project.undo().label) }
        #expect(labels == ["marker.add", "aspect", "project.title"])
        var document = project.document
        document.logSequence = original.logSequence
        #expect(document == original)
        await project.close()
    }
}

@MainActor @Test func appliedIsOnDiskWhenApplyReturns() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let editor = try await TomaProject.open(url, mode: .edit, environment: environment)
        _ = try await editor.apply(.setTitle("En disco"))
        _ = try await editor.apply(.cut(from: 1, to: 2))
        // Another reader, before the editor closes: it reads the log.
        let reader = try await TomaProject.open(url, mode: .read, environment: environment)
        #expect(reader.document.info?.title == "En disco")
        #expect(reader.document.sequence == editor.document.sequence)
        await reader.close()
        await editor.close()
    }
}

@MainActor @Test func saveFailedIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let io = APIFixtures.FailingIO()
        let environment = APIFixtures.environment(in: dir, journalIO: io.io)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        io.failWrites(with: .ENOSPC)
        let error = await APIFixtures.apiError { _ = try await project.apply(.setTitle("Lleno")) }
        #expect(error?.code == .refused)
        #expect(error?.message.contains("could not be saved") == true)
        io.failWrites(with: nil)
        await project.close()
    }
}

@MainActor @Test func everyCommandIsItsOwnUndoEvenInABurst() async throws {
    try await withTemporaryDirectory { dir in
        // Every step at the same instant: the editor's rule would join cuts of the same clip into one undo.
        let environment = APIFixtures.environment(in: dir, stoppedClock: true)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        let full = TimeMap(sequence: project.document.sequence).durationSeconds
        // From the end back, so the times do not move: each one cuts the clip `c-…` the one before left.
        let batch = await project.apply([.cut(from: 7, to: 8), .cut(from: 4, to: 5), .cut(from: 1, to: 2)])
        #expect(batch.error == nil && batch.results.map(\.label) == ["delete", "delete", "delete"])
        #expect(abs(TimeMap(sequence: project.document.sequence).durationSeconds - (full - 3)) < 0.001)
        for left in [2.0, 1, 0] {
            let undone = try await project.undo()
            #expect(undone.label == "delete")
            #expect(abs(TimeMap(sequence: project.document.sequence).durationSeconds - (full - left)) < 0.001)
        }
        #expect(try await project.undo().label == "transcript.create")
        await project.close()
    }
}

@MainActor @Test func aFullDiskRefusesAnImportInsteadOfWaiting() async throws {
    try await withTemporaryDirectory { dir in
        let disk = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .hfsPlus, in: dir)
        defer { try? disk.detach(force: true) }
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: disk.mountPoint, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        _ = try await project.apply(.setTitle("Lleno"))

        // A style of the library whose image the project does not have.
        let scratch = try ProjectPackage.create(in: dir, name: "Scratch", app: APIFixtures.app, now: Date())
        let styleImage = dir.appending(path: "Style.png")
        try png(red: 0.2).write(to: styleImage)
        var look = DefaultStyle.toma
        look.style.background = .image(file: try AssetImport.copy(styleImage, into: scratch))
        try await StyleLibrary(directory: environment.stylesFolder)
            .save(NamedStyle(id: "0a1b2c3d", name: "Imagen", look: look, camera: .newProjects), imageFrom: scratch)
        let image = dir.appending(path: "Back.png")
        try png(red: 0.7).write(to: image)
        try await APIFixtures.fill(disk.mountPoint)

        for command in [ProjectCommand.setBackground(.image(file: image.path)), .applyStyle(id: "0a1b2c3d")] {
            // Without the fix it would wait for room forever: given up here after 20 s (cancelled, it says why).
            let done = Done()
            let running = Task {
                defer { done.value = true }
                return await APIFixtures.apiError { _ = try await project.apply(command) }
            }
            let finished = await eventually(timeout: .seconds(20)) { done.value }
            if !finished { running.cancel() }
            #expect(finished, "\(command.name) waited for room")
            let error = await running.value
            #expect(error?.code == .refused, "\(command.name)")
            #expect(error?.message.contains("could not be saved") == true, "\(command.name): \(error?.message ?? "")")
        }
        #expect(project.document.info?.title == "Lleno")
        try FileManager.default.removeItem(at: disk.mountPoint.appending(path: "filler"))
        await project.close()
    }
}

@MainActor private final class Done {
    var value = false
}

/// A 32 × 32 PNG filled with `red`.
private func png(red: Double) throws -> Data {
    guard let context = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw TestSupportError.failed("no context") }
    context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let data = NSMutableData()
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
    else { throw TestSupportError.failed("no image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
    return data as Data
}
