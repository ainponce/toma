// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import Library
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

private let app = AppInfo(name: "Tests", version: "0")

// MARK: - Doubles

/// The app around the library, as each test sets it: whether it records, which packages it has open and which of those
/// have changes it could not write. `close` closes the window, as the app would.
final class FakeAppState: LibraryAppState {
    private struct State {
        var recording = false
        var recordingAnswers = 0
        var open: Set<String> = []
        var unsaved: Set<String> = []
        var closed: [String] = []
    }

    private let state = Mutex(State())

    var recording: Bool {
        get { state.withLock { $0.recording } }
        set { state.withLock { $0.recording = newValue } }
    }

    /// How many times `isRecording()` answered `true`: a paused copy or deletion asks again every 50 ms, so two answers
    /// mean it is waiting, and four more that 200 ms went by while it waited.
    var recordingAnswers: Int { state.withLock { $0.recordingAnswers } }

    /// The packages `close` was called for, in order, by path.
    var closed: [String] { state.withLock { $0.closed } }

    func open(_ url: URL, unsaved: Bool = false) {
        state.withLock { state in
            state.open.insert(Self.key(url))
            if unsaved { state.unsaved.insert(Self.key(url)) }
        }
    }

    func isRecording() -> Bool {
        state.withLock { state in
            if state.recording { state.recordingAnswers += 1 }
            return state.recording
        }
    }

    func isOpenHere(_ url: URL) -> Bool { state.withLock { $0.open.contains(Self.key(url)) } }

    func hasUnsavedChanges(_ url: URL) -> Bool { state.withLock { $0.unsaved.contains(Self.key(url)) } }

    func close(_ url: URL) async {
        state.withLock { state in
            state.open.remove(Self.key(url))
            state.unsaved.remove(Self.key(url))
            state.closed.append(Self.key(url))
        }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}

/// `isLockHeld` as the library has it by default (`RecordingLock.isHeld`), writing down every lock file it was asked
/// about (H18): the library probes locks only just before an action that changes where a project is.
final class LockProbes: Sendable {
    private let asked = Mutex<[String]>([])
    private let answer: @Sendable (URL) -> Bool

    init(answer: @escaping @Sendable (URL) -> Bool = { RecordingLock.isHeld(at: $0) }) {
        self.answer = answer
    }

    /// The lock files asked about so far, by path, in order.
    var paths: [String] { asked.withLock { $0 } }

    func reset() { asked.withLock { $0 = [] } }

    func isHeld(_ url: URL) -> Bool {
        asked.withLock { $0.append(url.standardizedFileURL.path) }
        return answer(url)
    }
}

/// The Trash of macOS for the tests: what it is given is moved into a folder of the test, never to the real one (H21).
final class TrashDouble: Sendable {
    let folder: URL
    private let given = Mutex<[String]>([])

    init(folder: URL) {
        self.folder = folder
    }

    /// What was put in it, by the path it had.
    var trashed: [String] { given.withLock { $0 } }

    func trash(_ url: URL) throws {
        given.withLock { $0.append(url.standardizedFileURL.path) }
        try FileManager.default.moveItem(at: url, to: folder.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
    }
}

/// A projects folder at `<folder>/Projects`, its library and the doubles around it. A test that changes the library's
/// records flushes them before `folder` is removed, so that no write comes after.
struct Rig {
    let projects: URL
    let app = FakeAppState()
    let probes: LockProbes
    let macTrash: TrashDouble
    let records: LibraryRecordsStore
    let operations: LibraryOperations

    var trash: URL { ProjectTrash.folder(in: projects) }

    /// `locks` answers `isLockHeld` (by default, `RecordingLock.isHeld`).
    init(
        in folder: URL, projects: URL? = nil, fileSystem: any LibraryFileSystem = SystemFileSystem(),
        locks: @escaping @Sendable (URL) -> Bool = { RecordingLock.isHeld(at: $0) }
    ) throws {
        probes = LockProbes(answer: locks)
        self.projects = projects ?? folder.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: self.projects, withIntermediateDirectories: true)
        let macTrashFolder = folder.appending(path: "MacTrash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macTrashFolder, withIntermediateDirectories: false)
        macTrash = TrashDouble(folder: macTrashFolder)
        records = LibraryRecordsStore(url: folder.appending(path: "library-\(UUID().uuidString).json"))
        let probes = probes
        let macTrash = macTrash
        operations = LibraryOperations(
            projectsFolder: self.projects, fileSystem: fileSystem, records: records, app: app,
            isLockHeld: { probes.isHeld($0) }, trash: { try macTrash.trash($0) })
    }
}

// MARK: - Helpers

/// A project named `name` in `folder`: its manifest, a take `take-001` (or those of `takes`) with `mediaBytes` bytes of
/// "media" each, its document and its edit log, a folder of cache.
@discardableResult
private func makeProject(
    _ name: String, in folder: URL, mediaBytes: Int = 4_096, takes: [String] = ["take-001"]
) throws -> ProjectPackage {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let package = try ProjectPackage.create(in: folder, name: name, app: app, now: Date())
    for (index, take) in takes.enumerated() {
        let track = package.trackDirectory(take: take, track: "display-1")
        try FileManager.default.createDirectory(at: track, withIntermediateDirectories: true)
        var media = Data(count: mediaBytes)
        media.withUnsafeMutableBytes { bytes in
            for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ index &+ name.utf8.count) }
        }
        try media.write(to: package.segmentURL(take: take, track: "display-1", index: 1))
        try Data("{\"t\":1}\n".utf8).write(to: package.eventsURL(take: take))
    }
    try Data("{\"documentVersion\":2,\"\(name)\":1}".utf8).write(to: package.editURL)
    try Data("{\"seq\":1}\n".utf8).write(to: package.editLogURL)
    try Data("thumb".utf8).write(to: package.cacheURL.appending(path: "thumb.heic"))
    return package
}

/// The names in `folder`, hidden ones included, sorted.
private func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// Where `url` is, as one string whatever its form (`/var` or `/private/var`, a `/` at its end): the real path of its
/// folder and its own name.
private func location(_ url: URL) -> String {
    let folder = url.deletingLastPathComponent().path
    guard let real = realpath(folder, nil) else { return url.standardizedFileURL.path }
    defer { free(real) }
    return String(cString: real) + "/" + url.lastPathComponent
}

private func signature(_ url: URL) throws -> FileSignature {
    let info = try SystemFileSystem().stat(url, withAddedDate: false)
    return FileSignature(size: info.size, modified: info.modified)
}

/// The lock files of the package at `url` the library asks about: its `edit.lock` and each take's `recording.lock`.
private func lockPaths(of url: URL, takes: [String] = ["take-001"], editLock: Bool = true) -> Set<String> {
    let package = ProjectPackage(url: url)
    var paths = Set(takes.map { package.lockURL(take: $0).standardizedFileURL.path })
    if editLock { paths.insert(package.editLockURL.standardizedFileURL.path) }
    return paths
}

/// The bytes of every regular file under `folder`.
private func bytes(under folder: URL) -> Int64 {
    guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let item as URL in items {
        total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

/// How many items there are under `folder`, folders included.
private func itemCount(under folder: URL) -> Int {
    FileManager.default.enumerator(atPath: folder.path)?.allObjects.count ?? 0
}

private func copyName(_ base: String, existing: [String]) -> String {
    ProjectNames.copyName(base, existing: existing, copy: "copia") { "copia \($0)" }
}

private let noProgress: @Sendable (Double) -> Void = { _ in }

/// What went wrong, if anything.
private func failure(of result: Result<Void, LibraryFailure>) -> LibraryFailure? {
    if case .failure(let failure) = result { return failure }
    return nil
}

// MARK: - Rename

@Test func renameRefusesInvalidAndTakenNames() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let old = try makeProject("Old", in: rig.projects)
        try makeProject("Demo", in: rig.projects)
        let before = try treeHash(old.url)

        #expect(await rig.operations.rename(old.url, to: "a/b") == .failure(.name(.slashOrColon)))
        #expect(await rig.operations.rename(old.url, to: "  ") == .failure(.name(.empty)))
        #expect(await rig.operations.rename(old.url, to: ".hidden") == .failure(.name(.leadingDot)))
        #expect(await rig.operations.rename(old.url, to: String(repeating: "a", count: 201)) == .failure(.name(.tooLong)))
        // As APFS compares names: case and normalization do not count.
        #expect(await rig.operations.rename(old.url, to: "demo") == .failure(.name(.taken)))
        #expect(try names(in: rig.projects) == ["Demo.toma", "Old.toma"])

        let renamed = try await rig.operations.rename(old.url, to: " Nuevo ").get()
        #expect(renamed.lastPathComponent == "Nuevo.toma")
        #expect(location(renamed) == location(rig.projects.appending(path: "Nuevo.toma")))
        #expect(try names(in: rig.projects) == ["Demo.toma", "Nuevo.toma"])
        #expect(try treeHash(renamed) == before)

        // Only its case: the same project, its name written another way.
        let recased = try await rig.operations.rename(renamed, to: "nuevo").get()
        #expect(recased.lastPathComponent == "nuevo.toma")
        #expect(try names(in: rig.projects) == ["Demo.toma", "nuevo.toma"])
        #expect(try treeHash(recased) == before)
        // Its own name: nothing to do.
        #expect(await rig.operations.rename(recased, to: "nuevo") == .success(recased))
    }
}

// MARK: - Duplicate

@Test func duplicateIsAByteForByteClone() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let original = try makeProject("x", in: rig.projects, mediaBytes: 1_048_576)
        let name = copyName("x", existing: ["x"])
        #expect(name == "x copia")
        let progress = Mutex<[Double]>([])

        let record = try await rig.operations.duplicate(original.url, named: name) { value in
            progress.withLock { $0.append(value) }
        }.get()
        #expect(record.copy.lastPathComponent == "x copia.toma")
        #expect(location(record.copy) == location(rig.projects.appending(path: "x copia.toma")))
        #expect(record.insideProjectsFolder)
        #expect(try treeHash(record.copy) == treeHash(original.url))
        let fileSystem = SystemFileSystem()
        #expect(try PackageIdentity(of: record.copy, in: fileSystem) != PackageIdentity(of: original.url, in: fileSystem))
        let copy = ProjectPackage(url: record.copy)
        #expect(record.editSignature == (try signature(copy.editURL)))
        #expect(record.logSignature == (try signature(copy.editLogURL)))
        // A clone: one step, and nothing hidden left behind.
        #expect(progress.withLock { $0 } == [1])
        #expect(try names(in: rig.projects) == ["x copia.toma", "x.toma"])
        // Duplicating changes where no project is: no lock is asked about.
        #expect(rig.probes.paths.isEmpty)

        // A copy of the copy is named from the original, as in the Finder.
        let second = copyName("x copia", existing: ["x", "x copia"])
        #expect(second == "x copia 2")
        let again = try await rig.operations.duplicate(record.copy, named: second, progress: noProgress).get()
        #expect(again.copy.lastPathComponent == "x copia 2.toma")
        #expect(try treeHash(again.copy) == treeHash(original.url))

        // A name that is not one, or is taken.
        #expect(await rig.operations.duplicate(original.url, named: "a:b", progress: noProgress) == .failure(.name(.slashOrColon)))
        #expect(await rig.operations.duplicate(original.url, named: "X COPIA", progress: noProgress) == .failure(.name(.taken)))
        #expect(try names(in: rig.projects) == ["x copia 2.toma", "x copia.toma", "x.toma"])
    }
}

@Test func tooLongACopyNameLeavesNothingBehind() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        // A name the Finder allows (245 bytes, 250 with `.toma`), longer than the library's 200: its copy's name,
        // « copia» more, no longer fits in the 255 bytes of a file name.
        let long = String(repeating: "a", count: 245)
        let original = try makeProject(long, in: rig.projects)
        let result = await rig.operations.duplicate(original.url, named: copyName(long, existing: [long]), progress: noProgress)
        #expect(result == .failure(.name(.tooLong)))
        // The hidden clone it made is gone.
        #expect(try names(in: rig.projects) == ["\(long).toma"])

        // Within the 255 bytes, a long name has its copy.
        let shorter = String(repeating: "b", count: 230)
        let other = try makeProject(shorter, in: rig.projects)
        let record = try await rig.operations.duplicate(other.url, named: copyName(shorter, existing: [shorter]), progress: noProgress).get()
        #expect(record.copy.lastPathComponent == "\(shorter) copia.toma")
    }
}

@Test func duplicateWithoutClonesCopiesAfterCheckingTheSpace() async throws {
    try await withTemporaryDirectory { folder in
        let image = try DiskImage.attach(sizeMegabytes: 64, fileSystem: .hfsPlus, in: folder)
        defer { try? image.detach(force: true) }
        let projects = image.mountPoint.appending(path: "Projects", directoryHint: .isDirectory)
        let rig = try Rig(in: folder, projects: projects)
        let original = try makeProject("x", in: projects, mediaBytes: 24 * 1_048_576)
        let before = try treeHash(original.url)
        let progress = Mutex<[Double]>([])

        let record = try await rig.operations.duplicate(original.url, named: "x copia") { value in
            progress.withLock { $0.append(value) }
        }.get()
        let values = progress.withLock { $0 }
        #expect(values.count > 10)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == 1)
        #expect(values.dropLast().allSatisfy { $0 < 1 })
        #expect(try treeHash(record.copy) == before)
        #expect(try PackageIdentity(of: record.copy, in: SystemFileSystem()) != PackageIdentity(of: original.url, in: SystemFileSystem()))
        // The dates of the copy's document and log are the original's, as a clone's are.
        #expect(try signature(ProjectPackage(url: record.copy).editURL) == signature(original.editURL))
        #expect(record.editSignature == (try signature(original.editURL)))
        #expect(try names(in: projects) == ["x copia.toma", "x.toma"])

        // A second copy does not fit: refused before anything is written.
        let needed = try SystemFileSystem().allocatedSize(of: original.url)
        let free = try SystemFileSystem().freeSpace(of: projects)
        try #require(needed > free)
        #expect(await rig.operations.duplicate(original.url, named: "x copia 2", progress: noProgress) == .failure(.noRoom(needed: needed)))
        #expect(try names(in: projects) == ["x copia.toma", "x.toma"])

        // A disk that says it has room and fills up during the copy: what was copied is removed.
        let roomy = DelayingFileSystem(volumes: [
            .init(
                root: image.mountPoint,
                info: DelayingFileSystem.volumeInfo(
                    uuid: "ROOMY", isInternal: false, isRemovable: true, mountPath: image.mountPoint.path),
                freeBytes: 1 << 40)
        ])
        let lying = try Rig(in: folder, projects: projects, fileSystem: roomy)
        #expect(await lying.operations.duplicate(original.url, named: "x copia 2", progress: noProgress) == .failure(.noRoom(needed: needed)))
        #expect(try names(in: projects) == ["x copia.toma", "x.toma"])
        #expect(try treeHash(original.url) == before)
        #expect(try SystemFileSystem().freeSpace(of: projects) >= free - 1_048_576)
    }
}

@Test func renamedByFinderDuringDuplicateKeepsBoth() async throws {
    try await withTemporaryDirectory { folder in
        let image = try DiskImage.attach(sizeMegabytes: 64, fileSystem: .hfsPlus, in: folder)
        defer { try? image.detach(force: true) }
        let projects = image.mountPoint.appending(path: "Projects", directoryHint: .isDirectory)
        let rig = try Rig(in: folder, projects: projects)
        let original = try makeProject("x", in: projects, mediaBytes: 16 * 1_048_576)
        let before = try treeHash(original.url)
        let renamedTo = projects.appending(path: "x renombrado.toma", directoryHint: .isDirectory)
        let renamed = Mutex(false)

        // The Finder renames the original while it is being copied.
        let record = try await rig.operations.duplicate(original.url, named: "x copia") { value in
            guard value < 1, !renamed.withLock({ $0 }) else { return }
            renamed.withLock { $0 = true }
            try? FileManager.default.moveItem(at: original.url, to: renamedTo)
        }.get()
        #expect(renamed.withLock { $0 })
        #expect(record.copy.lastPathComponent == "x copia.toma")
        #expect(try treeHash(record.copy) == before)
        #expect(try treeHash(renamedTo) == before)
        #expect(try names(in: projects) == ["x copia.toma", "x renombrado.toma"])
    }
}

@Test func copyPausesWhenARecordingStartsAndResumes() async throws {
    try await withTemporaryDirectory { folder in
        let image = try DiskImage.attach(sizeMegabytes: 128, fileSystem: .hfsPlus, in: folder)
        defer { try? image.detach(force: true) }
        let projects = image.mountPoint.appending(path: "Projects", directoryHint: .isDirectory)
        let rig = try Rig(in: folder, projects: projects)
        let original = try makeProject("x", in: projects, mediaBytes: 48 * 1_048_576)
        let before = try treeHash(original.url)
        let appState = rig.app
        let started = Mutex(false)

        // A recording starts a quarter of the way.
        let copying = Task {
            await rig.operations.duplicate(original.url, named: "x copia") { value in
                guard value >= 0.25, value < 1, !started.withLock({ $0 }) else { return }
                started.withLock { $0 = true }
                appState.recording = true
            }
        }
        // Asked twice: it is waiting.
        #expect(await eventually(timeout: .seconds(30)) { appState.recordingAnswers >= 2 })
        let hidden = try #require(try names(in: projects).first { $0.hasSuffix(".duplicating") })
        let partial = projects.appending(path: hidden, directoryHint: .isDirectory)
        let paused = bytes(under: partial)
        // Not one byte more while the take records, for four more askings: 200 ms.
        let answers = appState.recordingAnswers
        #expect(await eventually(timeout: .seconds(30)) { appState.recordingAnswers >= answers + 4 })
        #expect(bytes(under: partial) == paused)
        #expect(paused < 48 * 1_048_576)
        #expect(!exists(projects.appending(path: "x copia.toma")))

        appState.recording = false
        let record = try await copying.value.get()
        #expect(try treeHash(record.copy) == before)
        #expect(try names(in: projects) == ["x copia.toma", "x.toma"])
    }
}

// MARK: - Trash and restore

@Test func trashAndRestoreRoundTrip() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let clientes = rig.projects.appending(path: "Clientes", directoryHint: .isDirectory)
        let x = try makeProject("x", in: clientes)
        let before = try treeHash(x.url)
        let identity = try PackageIdentity(of: x.url, in: SystemFileSystem())

        let trashed = try await rig.operations.moveToTrash(x.url).get()
        #expect(location(trashed) == location(rig.trash.appending(path: "x.toma")))
        #expect(try treeHash(trashed) == before)
        #expect(!exists(x.url))
        // Where it came from, by its identity.
        let origin = try #require(await rig.records.records.trashOrigins[identity.string])
        #expect(origin.path == clientes.path)
        #expect(origin.bookmark != nil)

        let restored = try await rig.operations.restore(trashed).get()
        #expect(location(restored) == location(x.url))
        #expect(try treeHash(restored) == before)
        #expect(try names(in: rig.trash).isEmpty)
        #expect(await rig.records.records.trashOrigins.isEmpty)

        // Its name was taken meanwhile: «x 2».
        let trashedAgain = try await rig.operations.moveToTrash(restored).get()
        try makeProject("x", in: clientes)
        let second = try await rig.operations.restore(trashedAgain).get()
        #expect(location(second) == location(clientes.appending(path: "x 2.toma")))
        #expect(try treeHash(second) == before)
        #expect(try names(in: clientes) == ["x 2.toma", "x.toma"])

        // The folder it came from is gone: to the projects folder.
        let third = try await rig.operations.moveToTrash(second).get()
        #expect(third.lastPathComponent == "x 2.toma")
        try FileManager.default.removeItem(at: clientes)
        let fourth = try await rig.operations.restore(third).get()
        #expect(location(fourth) == location(rig.projects.appending(path: "x 2.toma")))
        #expect(try treeHash(fourth) == before)

        // Its folder was renamed: the bookmark follows it.
        let moving = rig.projects.appending(path: "Antes", directoryHint: .isDirectory)
        let y = try makeProject("y", in: moving)
        let trashedY = try await rig.operations.moveToTrash(y.url).get()
        let movedTo = rig.projects.appending(path: "Después", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: moving, to: movedTo)
        let restoredY = try await rig.operations.restore(trashedY).get()
        #expect(location(restoredY) == location(movedTo.appending(path: "y.toma")))

        // Moved out of the projects folder meanwhile: not followed there.
        let away = folder.appending(path: "Away", directoryHint: .isDirectory)
        let leaving = rig.projects.appending(path: "Leaving", directoryHint: .isDirectory)
        let z = try makeProject("z", in: leaving)
        let trashedZ = try await rig.operations.moveToTrash(z.url).get()
        try FileManager.default.moveItem(at: leaving, to: away)
        let restoredZ = try await rig.operations.restore(trashedZ).get()
        #expect(location(restoredZ) == location(rig.projects.appending(path: "z.toma")))
        // Restoring asks no lock.
        #expect(rig.probes.paths.allSatisfy { !$0.contains("/Trash/") })
        await rig.records.flush()
    }
}

@Test func outsideTheFolderIsNotTrashed() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let elsewhere = try makeProject("y", in: folder.appending(path: "Desktop", directoryHint: .isDirectory))
        let before = try treeHash(elsewhere.url)
        #expect(await rig.operations.moveToTrash(elsewhere.url) == .failure(.outsideProjectsFolder))
        #expect(try treeHash(elsewhere.url) == before)
        #expect(!exists(rig.trash))
        #expect(rig.probes.paths.isEmpty)

        // Nor is what is in the trash moved there again; restore and delete take only what is in the trash.
        let x = try makeProject("x", in: rig.projects)
        let trashed = try await rig.operations.moveToTrash(x.url).get()
        #expect(await rig.operations.moveToTrash(trashed) == .failure(.outsideProjectsFolder))
        #expect(await rig.operations.restore(elsewhere.url) == .failure(.outsideProjectsFolder))
        let kept = try makeProject("kept", in: rig.projects)
        #expect(failure(of: await rig.operations.deleteForever([trashed, kept.url]) { _, _, _ in }) == .outsideProjectsFolder)
        #expect(failure(of: await rig.operations.deleteForever([elsewhere.url]) { _, _, _ in }) == .outsideProjectsFolder)
        #expect(exists(trashed) && exists(kept.url) && exists(elsewhere.url))
        #expect(try names(in: rig.trash) == ["x.toma"])
        await rig.records.flush()
    }
}

@Test func nothingWritesInsideAPackage() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let x = try makeProject("x", in: rig.projects, takes: ["take-001", "take-002"])
        let before = try treeHash(x.url)
        let package = { (url: URL) in ProjectPackage(url: url) }
        let dates = try [x.manifestURL, x.editURL, x.editLogURL].map(signature)
        func check(_ url: URL) throws {
            #expect(try treeHash(url) == before)
            let now = try [package(url).manifestURL, package(url).editURL, package(url).editLogURL].map(signature)
            #expect(now == dates)
        }

        let renamed = try await rig.operations.rename(x.url, to: "y").get()
        try check(renamed)
        let trashed = try await rig.operations.moveToTrash(renamed).get()
        try check(trashed)
        let restored = try await rig.operations.restore(trashed).get()
        try check(restored)
        // Its locks were asked about, never made: no edit.lock nor recording.lock was left in it (treeHash).
        #expect(!rig.probes.paths.isEmpty)
        await rig.records.flush()
    }
}

// MARK: - Locks and the app's state

@Test func lockedProjectsAreRefusedJustBefore() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let x = try makeProject("x", in: rig.projects)

        // Another app's editor has it open (edit.lock), or a take of it is being recorded (recording.lock).
        for lockURL in [x.editLockURL, x.lockURL(take: "take-001")] {
            let lock = try RecordingLock.acquire(at: lockURL, info: .current(now: Date()))
            #expect(await rig.operations.rename(x.url, to: "y") == .failure(.openElsewhere))
            #expect(await rig.operations.moveToTrash(x.url) == .failure(.openElsewhere))
            lock.release()
            #expect(try names(in: rig.projects) == ["x.toma"])
        }

        let trashed = try await rig.operations.moveToTrash(x.url).get()
        let inTrash = ProjectPackage(url: trashed)
        for lockURL in [inTrash.editLockURL, inTrash.lockURL(take: "take-001")] {
            let lock = try RecordingLock.acquire(at: lockURL, info: .current(now: Date()))
            #expect(failure(of: await rig.operations.deleteForever([trashed]) { _, _, _ in }) == .openElsewhere)
            lock.release()
            #expect(try names(in: rig.trash) == ["x.toma"])
        }

        // With the locks free, it goes.
        #expect(failure(of: await rig.operations.deleteForever([trashed]) { _, _, _ in }) == nil)
        #expect(try names(in: rig.trash).isEmpty)
        await rig.records.flush()
    }
}

@Test func locksAreAskedOnlyJustBeforeAMove() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let takes = ["take-001", "take-002"]
        let x = try makeProject("x", in: rig.projects, takes: takes)
        try makeProject("other", in: rig.projects)

        let record = try await rig.operations.duplicate(x.url, named: "x copia", progress: noProgress).get()
        #expect(rig.probes.paths.isEmpty)

        let y = try await rig.operations.rename(x.url, to: "y").get()
        #expect(Set(rig.probes.paths) == lockPaths(of: x.url, takes: takes))
        rig.probes.reset()

        // Open in this app: its own editor holds edit.lock, which is not asked about.
        rig.app.open(y)
        let z = try await rig.operations.rename(y, to: "z").get()
        #expect(Set(rig.probes.paths) == lockPaths(of: y, takes: takes, editLock: false))
        rig.probes.reset()

        // Its window is closed first, then its locks are asked about.
        rig.app.open(z)
        let trashed = try await rig.operations.moveToTrash(z).get()
        #expect(rig.app.closed == [FakeAppState.key(z)])
        #expect(Set(rig.probes.paths) == lockPaths(of: z, takes: takes))
        rig.probes.reset()

        let restored = try await rig.operations.restore(trashed).get()
        #expect(rig.probes.paths.isEmpty)
        let again = try await rig.operations.moveToTrash(restored).get()
        rig.probes.reset()
        #expect(failure(of: await rig.operations.deleteForever([again]) { _, _, _ in }) == nil)
        // Under its name, then once hidden, where nothing can open it anew.
        let hiddenProbes = rig.probes.paths.filter { $0.contains("/Trash/.deleting-") }
        #expect(Set(rig.probes.paths.filter { !$0.contains("/Trash/.deleting-") }) == lockPaths(of: again, takes: takes))
        #expect(hiddenProbes.count == 3)
        let hiddenPackage = try #require(hiddenProbes.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        #expect(Set(hiddenProbes) == lockPaths(of: hiddenPackage, takes: takes))
        rig.probes.reset()

        #expect(try await rig.operations.undoDuplicate(record).get().lastPathComponent == "x copia.toma")
        #expect(Set(rig.probes.paths) == lockPaths(of: record.copy, takes: takes))
        await rig.records.flush()
    }
}

/// What the app says of a project its editor has open, with a `close` of its own.
private final class EditorHere: LibraryAppState {
    private let closeEditor: @MainActor @Sendable () async -> Void

    init(close: @escaping @MainActor @Sendable () async -> Void) {
        closeEditor = close
    }

    func isRecording() -> Bool { false }
    func isOpenHere(_ url: URL) -> Bool { true }
    func hasUnsavedChanges(_ url: URL) -> Bool { false }
    func close(_ url: URL) async { await closeEditor() }
}

/// A project open in this app's editor holds its `edit.lock` (design §6.3): moving it to the trash closes the editor
/// first, and once its session let go of the lock the project goes. A `close` that leaves the session open (as the app's
/// was before Task 39 wired it) finds the editor's own lock and says the project is open in another app.
@MainActor @Test func trashingAProjectOpenHereWaitsForItsEditorToLetGo() async throws {
    try await withTemporaryDirectory { folder in
        let projects = folder.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let url = try #require(try await LibraryFixtures.folder(in: projects, kinds: [.v3]).first)
        let context = EditContext(
            app: app, cachesRoot: folder.appending(path: "Caches", directoryHint: .isDirectory), defaultStyle: .toma,
            now: { Date(timeIntervalSince1970: 1_794_800_000) }, makeID: { $0 + "00000001" })
        let session = try await EditSession.open(url, take: nil, context: context)
        #expect(session.access == .editable)
        let records = LibraryRecordsStore(url: folder.appending(path: "library.json"))
        func operations(_ app: EditorHere) -> LibraryOperations {
            LibraryOperations(projectsFolder: projects, fileSystem: SystemFileSystem(), records: records, app: app)
        }

        #expect(await operations(EditorHere {}).moveToTrash(url) == .failure(.openElsewhere))
        #expect(try names(in: projects).contains(url.lastPathComponent))

        let trashed = try await operations(EditorHere { await session.close() }).moveToTrash(url).get()
        #expect(trashed.deletingLastPathComponent().lastPathComponent == ProjectTrash.folderName)
        #expect(!session.hasUnsavedChanges)
        await records.flush()
    }
}

@Test func recordingRefusesRenameAndTrash() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let x = try makeProject("x", in: rig.projects)
        rig.app.recording = true
        #expect(await rig.operations.rename(x.url, to: "y") == .failure(.recording))
        #expect(await rig.operations.moveToTrash(x.url) == .failure(.recording))
        #expect(await rig.operations.duplicate(x.url, named: "x copia", progress: noProgress) == .failure(.recording))
        #expect(try names(in: rig.projects) == ["x.toma"])
        #expect(rig.probes.paths.isEmpty)

        // An editor that could not write what it has: no copy nor trash of what is on disk.
        rig.app.recording = false
        rig.app.open(x.url, unsaved: true)
        #expect(await rig.operations.duplicate(x.url, named: "x copia", progress: noProgress) == .failure(.unsavedChanges))
        #expect(await rig.operations.moveToTrash(x.url) == .failure(.unsavedChanges))
        #expect(rig.app.closed.isEmpty)
        #expect(try names(in: rig.projects) == ["x.toma"])
    }
}

// MARK: - Delete

@Test func deleteRenamesFirstThenDeletes() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let x = try makeProject("x", in: rig.projects)
        let identity = try PackageIdentity(of: x.url, in: SystemFileSystem())
        let trashed = try await rig.operations.moveToTrash(x.url).get()
        #expect(await rig.records.records.trashOrigins[identity.string] != nil)
        let trash = rig.trash
        let seen = Mutex<[[String]]>([])
        let events = Mutex<[String]>([])

        let result = await rig.operations.deleteForever([trashed]) { done, total, paused in
            events.withLock { $0.append("\(done)/\(total)\(paused ? " paused" : "")") }
            seen.withLock { $0.append((try? names(in: trash)) ?? []) }
        }
        #expect(failure(of: result) == nil)
        #expect(events.withLock { $0 } == ["0/1", "1/1"])
        // Before anything was deleted it had left its name: hidden, out of every list.
        let first = try #require(seen.withLock { $0.first })
        #expect(first.count == 1)
        #expect(first.allSatisfy { $0.hasPrefix(".deleting-") })
        #expect(try names(in: rig.trash).isEmpty)
        #expect(await rig.records.records.trashOrigins.isEmpty)

        // A deletion a crash left: finished, and nothing else touched.
        let outside = try makeProject("outside", in: rig.projects)
        let outsideHash = try treeHash(outside.url)
        let kept = try makeProject("kept", in: rig.trash)
        let keptHash = try treeHash(kept.url)
        let leftover = try makeProject("leftover", in: folder.appending(path: "staging", directoryHint: .isDirectory))
        try FileManager.default.moveItem(at: leftover.url, to: rig.trash.appending(path: ".deleting-\(UUID().uuidString)"))
        // A link among them is removed itself, never followed.
        try FileManager.default.createSymbolicLink(
            at: rig.trash.appending(path: ".deleting-\(UUID().uuidString)"), withDestinationURL: outside.url)
        let hidden = rig.trash.appending(path: ".other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: hidden.appending(path: "file"))

        await rig.operations.finishPendingDeletions()
        #expect(try names(in: rig.trash) == [".other", "kept.toma"])
        #expect(try treeHash(kept.url) == keptHash)
        #expect(try treeHash(outside.url) == outsideHash)
        #expect(try names(in: hidden) == ["file"])
        // With nothing pending, nothing happens.
        await rig.operations.finishPendingDeletions()
        #expect(try names(in: rig.trash) == [".other", "kept.toma"])
        await rig.records.flush()
    }
}

@Test func whatCannotBeDeletedGoesBackToItsName() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let a = try await rig.operations.moveToTrash(try makeProject("a", in: rig.projects).url).get()
        let b = try await rig.operations.moveToTrash(try makeProject("b", in: rig.projects).url).get()
        let c = try await rig.operations.moveToTrash(try makeProject("c", in: rig.projects).url).get()
        // A folder of `b` whose files cannot be removed.
        let locked = b.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("stays".utf8).write(to: locked.appending(path: "file"))
        try #require(chmod(locked.path, 0o555) == 0)
        defer { chmod(locked.path, 0o755) }
        let events = Mutex<[String]>([])

        let result = await rig.operations.deleteForever([a, b, c]) { done, total, _ in
            events.withLock { $0.append("\(done)/\(total)") }
        }
        #expect(failure(of: result) == .someNotDeleted(1))
        #expect(events.withLock { $0 }.first == "0/3")
        #expect(events.withLock { $0 }.last == "2/3")
        // Under its name again, in the trash, with what could not be deleted.
        #expect(try names(in: rig.trash) == ["b.toma"])
        #expect(try Data(contentsOf: locked.appending(path: "file")) == Data("stays".utf8))
        await rig.records.flush()
    }
}

@Test func emptyingPausesWhileRecording() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        var trashed: [URL] = []
        for name in ["a", "b", "c", "d", "e"] {
            let package = try makeProject(name, in: rig.projects, takes: (1...20).map { String(format: "take-%03d", $0) })
            trashed.append(try await rig.operations.moveToTrash(package.url).get())
        }
        let appState = rig.app
        let events = Mutex<[String]>([])
        let started = Mutex(false)

        // A recording starts once the first project is deleted.
        let emptying = Task {
            await rig.operations.deleteForever(trashed) { done, total, paused in
                events.withLock { $0.append("\(done)/\(total)\(paused ? " paused" : "")") }
                guard done == 1, !started.withLock({ $0 }) else { return }
                started.withLock { $0 = true }
                appState.recording = true
            }
        }
        #expect(await eventually(timeout: .seconds(30)) { events.withLock { $0.contains("1/5 paused") } })
        let paused = itemCount(under: rig.trash)
        // Nothing more is deleted while the take records, for four more askings.
        let answers = appState.recordingAnswers
        #expect(await eventually(timeout: .seconds(30)) { appState.recordingAnswers >= answers + 4 })
        #expect(itemCount(under: rig.trash) == paused)
        #expect(paused > 0)

        appState.recording = false
        #expect(failure(of: await emptying.value) == nil)
        #expect(events.withLock { $0 } == ["0/5", "1/5", "1/5 paused", "1/5", "2/5", "3/5", "4/5", "5/5"])
        #expect(try names(in: rig.trash).isEmpty)
        await rig.records.flush()
    }
}

// MARK: - Undo a duplicate

@Test func undoDuplicateNeverDeletes() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let x = try makeProject("x", in: rig.projects)

        // In the projects folder: the copy goes to the library's trash, and can be restored.
        let record = try await rig.operations.duplicate(x.url, named: "x copia", progress: noProgress).get()
        let trashed = try await rig.operations.undoDuplicate(record).get()
        #expect(location(trashed) == location(rig.trash.appending(path: "x copia.toma")))
        #expect(!exists(record.copy))
        #expect(rig.macTrash.trashed.isEmpty)
        let restored = try await rig.operations.restore(trashed).get()
        #expect(location(restored) == location(record.copy))

        // Elsewhere: to the Trash of macOS (the double), never deleted.
        let desktop = folder.appending(path: "Desktop", directoryHint: .isDirectory)
        let y = try makeProject("y", in: desktop)
        let outside = try await rig.operations.duplicate(y.url, named: "y copia", progress: noProgress).get()
        #expect(!outside.insideProjectsFolder)
        let hash = try treeHash(outside.copy)
        #expect(await rig.operations.undoDuplicate(outside) == .success(outside.copy))
        #expect(rig.macTrash.trashed == [FakeAppState.key(outside.copy)])
        #expect(!exists(outside.copy))
        let inMacTrash = try #require(try names(in: rig.macTrash.folder).first)
        #expect(try treeHash(rig.macTrash.folder.appending(path: inMacTrash)) == hash)

        // Opened or changed since it was made: refused, and the copy stays.
        let copy2 = try await rig.operations.duplicate(x.url, named: "x copia 2", progress: noProgress).get()
        let lock = try RecordingLock.acquire(at: ProjectPackage(url: copy2.copy).editLockURL, info: .current(now: Date()))
        #expect(await rig.operations.undoDuplicate(copy2) == .failure(.copyOpenedOrChanged))
        lock.release()
        rig.app.open(copy2.copy)
        #expect(await rig.operations.undoDuplicate(copy2) == .failure(.copyOpenedOrChanged))
        #expect(exists(copy2.copy))

        let copy3 = try await rig.operations.duplicate(x.url, named: "x copia 3", progress: noProgress).get()
        let edit = ProjectPackage(url: copy3.copy).editURL
        let later = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: edit.path)
        #expect(await rig.operations.undoDuplicate(copy3) == .failure(.copyOpenedOrChanged))
        #expect(exists(copy3.copy))

        let copy4 = try await rig.operations.duplicate(x.url, named: "x copia 4", progress: noProgress).get()
        let log = try FileHandle(forWritingTo: ProjectPackage(url: copy4.copy).editLogURL)
        try log.seekToEnd()
        try log.write(contentsOf: Data("{\"seq\":2}\n".utf8))
        try log.close()
        #expect(await rig.operations.undoDuplicate(copy4) == .failure(.copyOpenedOrChanged))
        #expect(exists(copy4.copy))
        #expect(rig.macTrash.trashed.count == 1)

        // While a take records, or with a take of it being recorded: refused, and the copy stays.
        await rig.app.close(copy2.copy)
        rig.app.recording = true
        #expect(await rig.operations.undoDuplicate(copy2) == .failure(.recording))
        rig.app.recording = false
        let recordingLock = try RecordingLock.acquire(
            at: ProjectPackage(url: copy2.copy).lockURL(take: "take-001"), info: .current(now: Date()))
        #expect(await rig.operations.undoDuplicate(copy2) == .failure(.openElsewhere))
        recordingLock.release()
        #expect(exists(copy2.copy))

        // Closed again without a change: it can go.
        #expect(try await rig.operations.undoDuplicate(copy2).get().lastPathComponent == "x copia 2.toma")
        #expect(!exists(copy2.copy))
        await rig.records.flush()
    }
}

@Test func deletingWhileRecordingHidesThenWaits() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let a = try await rig.operations.moveToTrash(try makeProject("a", in: rig.projects).url).get()
        let b = try await rig.operations.moveToTrash(try makeProject("b", in: rig.projects).url).get()
        let appState = rig.app
        appState.recording = true
        let events = Mutex<[String]>([])

        let emptying = Task {
            await rig.operations.deleteForever([a, b]) { done, total, paused in
                events.withLock { $0.append("\(done)/\(total)\(paused ? " paused" : "")") }
            }
        }
        #expect(await eventually(timeout: .seconds(30)) { events.withLock { $0.contains("0/2 paused") } })
        // Out of every list at once (the user confirmed); deleted only once the take ends.
        let hidden = try names(in: rig.trash)
        #expect(hidden.count == 2 && hidden.allSatisfy { $0.hasPrefix(".deleting-") })
        let paused = itemCount(under: rig.trash)
        let answers = appState.recordingAnswers
        #expect(await eventually(timeout: .seconds(30)) { appState.recordingAnswers >= answers + 4 })
        #expect(itemCount(under: rig.trash) == paused)

        appState.recording = false
        #expect(failure(of: await emptying.value) == nil)
        #expect(events.withLock { $0 } == ["0/2", "0/2 paused", "0/2", "1/2", "2/2"])
        #expect(try names(in: rig.trash).isEmpty)
        await rig.records.flush()
    }
}

@Test func aLockTakenAsItIsHiddenPutsItBack() async throws {
    try await withTemporaryDirectory { folder in
        // Another app opens it just as it is hidden: its locks are free under its name, taken under the hidden one.
        let rig = try Rig(in: folder, locks: { $0.path.contains("/.deleting-") && $0.lastPathComponent == "edit.lock" })
        let trashed = try await rig.operations.moveToTrash(try makeProject("x", in: rig.projects).url).get()
        let before = try treeHash(trashed)

        #expect(failure(of: await rig.operations.deleteForever([trashed]) { _, _, _ in }) == .openElsewhere)
        #expect(try names(in: rig.trash) == ["x.toma"])
        #expect(try treeHash(trashed) == before)
        #expect(rig.probes.paths.contains { $0.contains("/Trash/.deleting-") })
        await rig.records.flush()
    }
}

@Test func aDeletionThatCannotGoBackToItsNameSaysSo() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let trashed = try await rig.operations.moveToTrash(try makeProject("x", in: rig.projects).url).get()
        let trash = rig.trash
        // Once it is hidden, the trash cannot be written to: the package cannot be removed from it, nor named again.
        let result = await rig.operations.deleteForever([trashed]) { done, _, _ in
            if done == 0 { chmod(trash.path, 0o555) }
        }
        chmod(trash.path, 0o755)
        // Not "still in the trash": it is hidden, and finished the next time.
        #expect(failure(of: result) == .posix(.EACCES))
        let left = try names(in: rig.trash)
        #expect(left.count == 1 && left.allSatisfy { $0.hasPrefix(".deleting-") })
        await rig.operations.finishPendingDeletions()
        #expect(try names(in: rig.trash).isEmpty)
        await rig.records.flush()
    }
}

// MARK: - Abandoned copies and quitting

@Test func abandonedCopiesAreSweptOnlyOnAnInternalDisk() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        func hiddenCopy(in parent: URL, name: String = ".\(UUID().uuidString).duplicating") throws -> URL {
            let url = parent.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url.appending(path: "takes"), withIntermediateDirectories: true)
            try Data("half".utf8).write(to: url.appending(path: "manifest.json"))
            return url
        }
        let clientes = rig.projects.appending(path: "Clientes", directoryHint: .isDirectory)
        let deep = rig.projects.appending(path: "A/B/C", directoryHint: .isDirectory)
        let swept = [try hiddenCopy(in: rig.projects), try hiddenCopy(in: clientes), try hiddenCopy(in: deep)]
        // Not looked into: the trash, a package, a hidden folder; nor a name that is not a copy's, nor a link.
        let x = try makeProject("x", in: rig.projects)
        let outside = folder.appending(path: "Outside", directoryHint: .isDirectory)
        let kept = [
            try hiddenCopy(in: rig.trash), try hiddenCopy(in: x.url), try hiddenCopy(in: rig.projects.appending(path: ".hidden")),
            try hiddenCopy(in: rig.projects, name: ".not-a-uuid.duplicating"), try hiddenCopy(in: outside),
        ]
        let link = rig.projects.appending(path: ".\(UUID().uuidString).duplicating", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let outsideHash = try treeHash(outside)

        await rig.operations.finishPendingDeletions()
        #expect(swept.allSatisfy { !exists($0) })
        #expect(kept.allSatisfy(exists))
        #expect(exists(link))
        #expect(try treeHash(outside) == outsideHash)
        #expect(try names(in: clientes).isEmpty)

        // A projects folder on a disk that can be pulled out is not looked at by itself (design §6.5).
        let image = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .apfs, in: folder)
        defer { try? image.detach(force: true) }
        let removable = try Rig(in: folder, projects: image.mountPoint.appending(path: "Projects", directoryHint: .isDirectory))
        let left = try hiddenCopy(in: removable.projects)
        await removable.operations.finishPendingDeletions()
        #expect(exists(left))
    }
}

@Test func aCopyInProgressIsNotSweptAndQuittingWaitsForIt() async throws {
    try await withTemporaryDirectory { folder in
        let image = try DiskImage.attach(sizeMegabytes: 96, fileSystem: .hfsPlus, in: folder)
        defer { try? image.detach(force: true) }
        let projects = image.mountPoint.appending(path: "Projects", directoryHint: .isDirectory)
        // An internal disk without clones (HFS+, as an internal disk): a copy takes long enough to be met.
        let counting = CountingFileSystem(
            base: DelayingFileSystem(volumes: [
                .init(root: image.mountPoint, info: DelayingFileSystem.volumeInfo(uuid: "INTERNAL", mountPath: image.mountPoint.path))
            ]))
        let rig = try Rig(in: folder, projects: projects, fileSystem: counting)
        let original = try makeProject("x", in: projects, mediaBytes: 24 * 1_048_576)
        let before = try treeHash(original.url)
        let abandoned = projects.appending(path: ".\(UUID().uuidString).duplicating", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        let appState = rig.app
        let started = Mutex(false)

        let copying = Task {
            await rig.operations.duplicate(original.url, named: "x copia") { value in
                guard value >= 0.25, value < 1, !started.withLock({ $0 }) else { return }
                started.withLock { $0 = true }
                appState.recording = true
            }
        }
        #expect(await eventually(timeout: .seconds(30)) { appState.recordingAnswers >= 2 })
        let quit = Mutex(false)
        let quitting = Task {
            await rig.operations.waitForCopies()
            quit.withLock { $0 = true }
        }
        counting.reset()
        let sweeping = Task { await rig.operations.finishPendingDeletions() }
        // The sweep has looked at the projects folder while the copy is half made.
        #expect(await eventually(timeout: .seconds(30)) {
            counting.urls(of: .list).contains { $0.standardizedFileURL.path == projects.standardizedFileURL.path }
        })
        #expect(!quit.withLock { $0 })

        appState.recording = false
        let record = try await copying.value.get()
        await quitting.value
        await sweeping.value
        #expect(quit.withLock { $0 })
        #expect(try treeHash(record.copy) == before)
        #expect(!exists(abandoned))
        #expect(try names(in: projects) == ["x copia.toma", "x.toma"])
    }
}

// MARK: - The original moved, the disk full

/// A file system as `base`, which calls `onFreeSpace` before it answers `freeSpace(of:)`.
private final class HookedFileSystem: LibraryFileSystem {
    private let base = SystemFileSystem()
    private let onFreeSpace: @Sendable () -> Void

    init(onFreeSpace: @escaping @Sendable () -> Void) {
        self.onFreeSpace = onFreeSpace
    }

    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat { try base.stat(url, withAddedDate: withAddedDate) }
    func volume(of url: URL) throws -> VolumeInfo { try base.volume(of: url) }
    func read(_ url: URL, maxBytes: Int) throws -> Data { try base.read(url, maxBytes: maxBytes) }
    func allocatedSize(of package: URL) throws -> Int64 { try base.allocatedSize(of: package) }

    func freeSpace(of url: URL) throws -> Int64 {
        onFreeSpace()
        return try base.freeSpace(of: url)
    }
}

@Test func aDuplicateMeasuresTheOriginalWhereItIsNow() async throws {
    try await withTemporaryDirectory { folder in
        let image = try DiskImage.attach(sizeMegabytes: 32, fileSystem: .hfsPlus, in: folder)
        defer { try? image.detach(force: true) }
        let projects = image.mountPoint.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
        let original = projects.appending(path: "x.toma", directoryHint: .isDirectory)
        let renamedTo = projects.appending(path: "x renombrado.toma", directoryHint: .isDirectory)
        // The Finder renames the original once it is open, before it is measured.
        let renamed = Mutex(false)
        let hooked = HookedFileSystem {
            guard !renamed.withLock({ $0 }) else { return }
            renamed.withLock { $0 = true }
            try? FileManager.default.moveItem(at: original, to: renamedTo)
        }
        let rig = try Rig(in: folder, projects: projects, fileSystem: hooked)
        try makeProject("x", in: projects, mediaBytes: 2 * 1_048_576)
        let before = try treeHash(original)

        let record = try await rig.operations.duplicate(original, named: "x copia", progress: noProgress).get()
        #expect(renamed.withLock { $0 })
        #expect(try treeHash(record.copy) == before)
        #expect(try names(in: projects) == ["x copia.toma", "x renombrado.toma"])
    }
}

@Test func aCloneWithoutRoomSaysSo() async throws {
    try await withTemporaryDirectory { folder in
        let image = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .apfs, in: folder)
        defer { try? image.detach(force: true) }
        let projects = image.mountPoint.appending(path: "Projects", directoryHint: .isDirectory)
        let rig = try Rig(in: folder, projects: projects)
        let original = try makeProject("x", in: projects, mediaBytes: 1_048_576)
        for number in 1...300 { try Data("\(number)".utf8).write(to: original.cacheURL.appending(path: "\(number)")) }
        // The disk filled up to the last block.
        let filler = image.mountPoint.appending(path: "filler")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        let block = Data(count: 65_536)
        while (try? handle.write(contentsOf: block)) != nil {}
        try? handle.close()
        let needed = try SystemFileSystem().allocatedSize(of: original.url)

        #expect(await rig.operations.duplicate(original.url, named: "x copia", progress: noProgress) == .failure(.noRoom(needed: needed)))
        #expect(try names(in: projects) == ["x.toma"])
    }
}

@Test func undoLooksWhereTheCopyIsNow() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let x = try makeProject("x", in: rig.projects)
        let y = try makeProject("y", in: folder.appending(path: "Desktop", directoryHint: .isDirectory))
        let inside = try await rig.operations.duplicate(x.url, named: "x copia", progress: noProgress).get()
        let outside = try await rig.operations.duplicate(y.url, named: "y copia", progress: noProgress).get()

        // Records that say the opposite of where the copies are: where they are counts.
        var wrongOutside = outside
        wrongOutside.insideProjectsFolder = true
        #expect(await rig.operations.undoDuplicate(wrongOutside) == .success(outside.copy))
        #expect(rig.macTrash.trashed == [FakeAppState.key(outside.copy)])
        #expect(!exists(rig.trash))

        var wrongInside = inside
        wrongInside.insideProjectsFolder = false
        let trashed = try await rig.operations.undoDuplicate(wrongInside).get()
        #expect(location(trashed) == location(rig.trash.appending(path: "x copia.toma")))
        #expect(rig.macTrash.trashed.count == 1)
        await rig.records.flush()
    }
}

// MARK: - Speed

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func renameTrashAndRestoreAreQuick() async throws {
    try await withTemporaryDirectory { folder in
        let rig = try Rig(in: folder)
        let clock = ContinuousClock()
        var rows: [(String, [Duration])] = [("rename", []), ("moveToTrash", []), ("restore", [])]
        for run in 0..<5 {
            let x = try makeProject("x\(run)", in: rig.projects.appending(path: "Clientes"), mediaBytes: 8 * 1_048_576)
            var url = x.url
            for index in rows.indices {
                let start = clock.now
                switch index {
                case 0: url = try await rig.operations.rename(url, to: "renamed \(run)").get()
                case 1: url = try await rig.operations.moveToTrash(url).get()
                default: url = try await rig.operations.restore(url).get()
                }
                rows[index].1.append(clock.now - start)
            }
        }
        for (name, times) in rows {
            let milliseconds = times.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1e3 }
            print("\(name): " + milliseconds.map { String(format: "%.2f ms", $0) }.joined(separator: ", "))
            #expect(times.allSatisfy { $0 <= .milliseconds(100) }, "\(name)")
        }
        await rig.records.flush()
    }
}
