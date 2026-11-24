// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import RecorderKitTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat
import Recovery

// Milestone 5c, Task R3 (fases 4 y 5 design §10.3, plan 5c decision 9): «Guardar los últimos N s» makes a new project of
// the library from the Replay's working package, whole or not at all.

private enum SaverFixture {
    static let app = AppInfo(name: "Toma", version: "0.5.0")
    static let name = "Repetición 2026-11-20 14.03.22"

    static func context(_ dir: URL, defaultStyle: DefaultStyle = .toma, styleDirectory: URL? = nil) -> EditContext {
        let count = Mutex(0)
        return EditContext(
            app: app, cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory), defaultStyle: defaultStyle,
            now: { Date(timeIntervalSince1970: 1_794_773_523) },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            },
            styleDirectory: styleDirectory)
    }

    static func projects(_ dir: URL) -> URL { dir.appending(path: "Projects", directoryHint: .isDirectory) }

    static func request(_ dir: URL, seconds: Int, name: String = name, context: EditContext? = nil) -> ReplaySaveRequest {
        ReplaySaveRequest(seconds: seconds, projectsFolder: projects(dir), name: name, context: context ?? self.context(dir))
    }

    /// The names in `folder`, sorted; none if it is not there.
    static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The end of the screen of `take`: the latest end of its screen's segments.
    static func screenEnd(of take: TakeRecord) throws -> HostTime {
        try #require(take.tracks.filter(\.kind.isScreen).flatMap(\.segments).compactMap(\.endHostTime).max())
    }

    /// Whether APFS says the file at `url` may share its blocks with another file, as a clone's do (`EF_MAY_SHARE_BLOCKS`
    /// of `ATTR_CMNEXT_EXT_FLAGS`); `nil` if the volume does not say.
    static func maySharesBlocks(_ url: URL) -> Bool? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(url.path, &list, bytes.baseAddress, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        // A `u_int32_t` length, then the `u_int64_t` flags, packed.
        let flags = buffer[4..<12].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
    }

    /// A 32 × 32 PNG, filled.
    static func png() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestSupportError.failed("no context") }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { throw TestSupportError.failed("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw TestSupportError.failed("no destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
        return data as Data
    }

    /// A Replay whose `freeze()` gives `result` (after `freezeDelay`), writing down each `freeze` and `thaw` in `calls`;
    /// `thaw()` calls `onThaw` first.
    final class Source: ReplaySource {
        private let result: Result<ReplaySnapshot, ReplayError>
        private let freezeDelay: Duration
        private let onThaw: (@Sendable () -> Void)?
        private let log = Mutex<[String]>([])

        init(
            _ result: Result<ReplaySnapshot, ReplayError>, freezeDelay: Duration = .zero, onThaw: (@Sendable () -> Void)? = nil
        ) {
            self.result = result
            self.freezeDelay = freezeDelay
            self.onThaw = onThaw
        }

        var calls: [String] { log.withLock { $0 } }
        var thaws: Int { calls.filter { $0 == "thaw" }.count }

        func freeze() async throws -> ReplaySnapshot {
            log.withLock { $0.append("freeze") }
            if freezeDelay > .zero { try? await Task.sleep(for: freezeDelay) }
            return try result.get()
        }

        func thaw() async {
            onThaw?()
            log.withLock { $0.append("thaw") }
        }
    }

    /// A value the closures of a test share.
    final class Box<Value: Sendable>: Sendable {
        private let mutex: Mutex<Value>

        init(_ value: Value) {
            mutex = Mutex(value)
        }

        var value: Value {
            get { mutex.withLock { $0 } }
            set { mutex.withLock { $0 = newValue } }
        }
    }

    /// The hidden folders of saves in `folder`.
    static func stagingFolders(in folder: URL) -> [URL] {
        names(in: folder).filter { $0.hasSuffix(ReplaySaver.stagingSuffix) }.map {
            folder.appending(path: $0, directoryHint: .isDirectory)
        }
    }

    /// Clones as the app does, but throws `EIO` for the files `fails` picks, before making them.
    static func failing(_ fails: @escaping @Sendable (URL) -> Bool) -> ReplayFileOps {
        ReplayFileOps { from, to in
            if fails(to) { throw POSIXError(.EIO) }
            try ReplayFileOps.cloneOrCopy(from, to: to)
        }
    }
}

@Suite struct ReplaySaverTests {
    @Test func savedProjectLastsNSecondsWithinAFrame() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let result = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            #expect(result.projectURL == SaverFixture.projects(dir).appending(path: SaverFixture.name + ".toma", directoryHint: .isDirectory))
            #expect(result.trackKinds == [.display, .camera, .microphone])
            #expect(abs(Double(result.duration.components.attoseconds) / 1e18 + Double(result.duration.components.seconds) - 3) < 1.0 / 60)

            let context = SaverFixture.context(dir)
            let (project, document) = try EditSession.readDocument(result.projectURL, take: nil, context: context)
            let end = try SaverFixture.screenEnd(of: project.take)
            let cut = end.adding(seconds: -3)
            #expect(abs(Double(TimeMap(sequence: document.sequence).duration) / 1e9 - 3) < 1.0 / 60)
            #expect(document.sequence.first?.start == cut)
            #expect(document.sequence.last?.end == end)
            // The segment across the cut is saved whole: the take starts at it, before the cut.
            let start = try #require(project.take.tracks.flatMap(\.segments).map(\.startHostTime).min())
            #expect(start < cut)
            #expect(start == fixture.start.adding(seconds: 4))
            #expect(fixture.thawCount == 1)
        }
    }

    @Test func savedProjectHasCursorCameraAndMic() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let result = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            let project = try LoadedProject.load(result.projectURL)
            #expect(project.take.tracks.map(\.kind) == [.display, .camera, .microphone])
            #expect(project.take.tracks.allSatisfy { $0.segments.map(\.index) == [1, 2] })
            // The camera's style in force where the take starts.
            #expect(project.take.cameraStyle == ReplayFixture.laterCameraStyle)

            // The state re-emitted at the start: the display's geometry, the cursor's image (with its PNG) and its position.
            let start = try #require(project.take.tracks.flatMap(\.segments).map(\.startHostTime).min())
            let first = project.events.prefix { $0.t == start }
            #expect(first.contains { if case .displayGeometry(1, _, _) = $0.kind { true } else { false } })
            #expect(first.contains { if case .cursor = $0.kind { true } else { false } })
            #expect(first.contains {
                if case let .cursorImage(hash, _, _, _) = $0.kind { hash == fixture.secondCursorHash } else { false }
            })
            #expect(project.events.allSatisfy { $0.t >= start })
            #expect(project.events.contains { if case .mouseDown = $0.kind { true } else { false } })
            let saved = project.package.cursorImageURL(take: "take-001", hash: fixture.secondCursorHash)
            #expect(try Data(contentsOf: saved)
                == Data(contentsOf: fixture.package.cursorImageURL(take: "take-001", hash: fixture.secondCursorHash)))
            // An image no saved event names stays behind.
            #expect(SaverFixture.names(in: project.package.cursorsDirectory(take: "take-001")) == [fixture.secondCursorHash + ".png"])

            // Every saved segment has its start, under its new index, and no other segment has one.
            let starts = project.events.compactMap { event -> String? in
                guard case let .segmentStarted(track, index) = event.kind else { return nil }
                return "\(track) \(index)"
            }
            #expect(Set(starts) == Set(project.take.tracks.flatMap { track in track.segments.map { "\(track.id) \($0.index)" } }))
        }
    }

    @Test func savedFilesAreClonesOfTheScratch() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let cut = try ReplayCut.make(take: fixture.snapshot.take, seconds: 3, takeID: "take-001")
            let cloned = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            let noClones = ReplayFileOps { from, to in
                try ReplayFileOps.cloneOrCopy(from, to: to, cloning: { _, _ in throw POSIXError(.ENOTSUP) })
            }
            let copied = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3), files: noClones)
            #expect(cut.files.count == 6)
            for file in cut.files {
                let original = try Data(contentsOf: fixture.package.url.appending(path: file.from))
                let clone = cloned.projectURL.appending(path: file.to)
                let copy = copied.projectURL.appending(path: file.to)
                #expect(try Data(contentsOf: clone) == original)
                #expect(try Data(contentsOf: copy) == original)
                if let shares = SaverFixture.maySharesBlocks(clone) {
                    #expect(shares, "\(file.to) is a clone")
                    #expect(SaverFixture.maySharesBlocks(copy) == false, "\(file.to) is a copy")
                }
            }
            #expect(fixture.thawCount == 2)
        }
    }

    @Test func savedManifestHasNoRotatedAndReadsAsPhase3() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            #expect(try String(decoding: Data(contentsOf: fixture.package.manifestURL), as: UTF8.self).contains("rotated"))
            let result = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            let package = ProjectPackage(url: result.projectURL)
            let data = try Data(contentsOf: package.manifestURL)
            #expect(!String(decoding: data, as: UTF8.self).contains("rotated"))
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
            #expect(manifest.formatVersion == 3)
            #expect(manifest.app == SaverFixture.app)
            let scratchID = try ManifestStore(package: fixture.package).manifest.projectID
            #expect(manifest.projectID != nil && manifest.projectID != scratchID)
            #expect(manifest.takes.map(\.id) == ["take-001"])
            let take = try #require(manifest.takes.first)
            #expect(take.status == .complete)
            for track in take.tracks {
                #expect(track.segments.map(\.index) == Array(1...track.segments.count))
                #expect(track.segments.map(\.file) == track.segments.map {
                    "takes/take-001/\(track.id)/seg-" + String(format: "%04d", $0.index) + ".mov"
                })
                #expect(track.segments.allSatisfy { $0.endReason == .stopped })
            }
            try manifest.validatePaths()
            #expect(RecoveryScanner.scan(package: package).isEmpty)
            #expect(RecoveryScanner.scan(directory: SaverFixture.projects(dir)).isEmpty)

            // Nothing of the working package's own: never its marker (`RecoveryScanner` would skip the project), its
            // event files or its lock.
            #expect(!ReplayScratch.isScratch(package))
            #expect(!SaverFixture.exists(package.url.appending(path: ReplayScratch.markerName)))
            #expect(SaverFixture.names(in: package.url) == ["cache", "edit-log.jsonl", "manifest.json", "takes"])
            #expect(SaverFixture.names(in: package.takeDirectory("take-001"))
                == ["camera-1", "cursors", "display-1", "events.jsonl", "microphone-1"])
            #expect(SaverFixture.names(in: SaverFixture.projects(dir)) == [SaverFixture.name + ".toma"])
            // The working package is as it was.
            #expect(ReplayScratch.isScratch(fixture.package))
            #expect(try ManifestStore(package: fixture.package).manifest.takes == [fixture.snapshot.take])
        }
    }

    @Test func keysMakeAVersion4Project() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8, keys: true)
            let result = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            let project = try LoadedProject.load(result.projectURL)
            #expect(project.manifest.formatVersion == 4)
            #expect(project.events.contains { if case .keyPress = $0.kind { true } else { false } })

            // Without them, version 3.
            let plain = try await ReplayFixture(in: dir.appending(path: "Plain", directoryHint: .isDirectory), seconds: 8)
            let other = try await ReplaySaver.save(from: plain.source, SaverFixture.request(dir, seconds: 3, name: "Plain"))
            #expect(try LoadedProject.load(other.projectURL).manifest.formatVersion == 3)
        }
    }

    @MainActor @Test func editorOpensItWithTheCut() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let result = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            let package = ProjectPackage(url: result.projectURL)
            #expect(!SaverFixture.exists(package.editURL))
            let log = try EditLogReader.read(package.editLogURL)
            #expect(log.entries.count == 1)
            guard case let .create(seq, created, app)? = log.entries.first else {
                Issue.record("no create")
                return
            }
            #expect(seq == 1 && created.logSequence == 1 && app == SaverFixture.app)
            #expect(log.createVersion == DocumentMigration.oldestVersion(holding: created, from: 2))

            let session = try await EditSession.open(result.projectURL, take: nil, context: SaverFixture.context(dir))
            #expect(session.access == .editable)
            let end = try SaverFixture.screenEnd(of: session.project.take)
            #expect(session.document.sequence.first?.start == end.adding(seconds: -3))
            #expect(session.document == created)
            await session.close()
            #expect(SaverFixture.exists(package.editURL))
        }
    }

    @MainActor @Test func newProjectsStyleImageIsCopiedIntoAssets() async throws {
        try await withTemporaryDirectory { dir in
            // The style's image, named as a package names it.
            let png = try SaverFixture.png()
            let source = try ProjectPackage.create(in: dir, name: "Source", app: SaverFixture.app, now: Date())
            let pngURL = dir.appending(path: "picture.png")
            try png.write(to: pngURL)
            let file = try AssetImport.copy(pngURL, into: source)
            let styleFolder = dir.appending(path: "Style", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: styleFolder, withIntermediateDirectories: true)
            try png.write(to: styleFolder.appending(path: String(file.dropFirst("assets/".count))))
            var style = DefaultStyle.toma
            style.style.background = .image(file: file)

            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let context = SaverFixture.context(dir, defaultStyle: style, styleDirectory: styleFolder)
            let result = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3, context: context))
            let package = ProjectPackage(url: result.projectURL)
            #expect(try Data(contentsOf: package.url.appending(path: file)) == png)
            guard case let .create(_, created, _)? = try EditLogReader.read(package.editLogURL).entries.first else {
                Issue.record("no create")
                return
            }
            #expect(created.style.background == .image(file: file))
            let session = try await EditSession.open(result.projectURL, take: nil, context: context)
            #expect(session.document.style.background == .image(file: file))
            await session.close()

            // Without the style's folder: Toma's background, and no `assets/`.
            let plain = try await ReplaySaver.save(
                from: fixture.source,
                SaverFixture.request(dir, seconds: 3, context: SaverFixture.context(dir, defaultStyle: style)))
            let plainPackage = ProjectPackage(url: plain.projectURL)
            #expect(!SaverFixture.exists(plainPackage.assetsURL))
            guard case let .create(_, plainCreated, _)? = try EditLogReader.read(plainPackage.editLogURL).entries.first else {
                Issue.record("no create")
                return
            }
            #expect(plainCreated.style.background == DefaultStyle.toma.style.background)
        }
    }

    @Test func nameTakenGetsTwo() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let projects = SaverFixture.projects(dir)
            let taken = projects.appending(path: SaverFixture.name + ".toma", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: taken.appending(path: "note.txt"))

            let second = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            let third = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            #expect(second.projectURL.lastPathComponent == SaverFixture.name + " 2.toma")
            #expect(third.projectURL.lastPathComponent == SaverFixture.name + " 3.toma")
            // What was there is untouched.
            #expect(SaverFixture.names(in: taken) == ["note.txt"])
            #expect(try Data(contentsOf: taken.appending(path: "note.txt")) == Data("mine".utf8))
            #expect(SaverFixture.names(in: projects) == [
                SaverFixture.name + " 2.toma", SaverFixture.name + " 3.toma", SaverFixture.name + ".toma",
            ])
        }
    }

    @Test func failedSaveLeavesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            // Every segment is cloned; the cursor's image, after them, fails.
            let files = SaverFixture.failing { $0.path.contains("/cursors/") }
            await #expect(throws: POSIXError(.EIO)) {
                try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3), files: files)
            }
            #expect(SaverFixture.names(in: SaverFixture.projects(dir)).isEmpty)
            #expect(fixture.thawCount == 1)
            // The working package keeps every file.
            for segment in fixture.snapshot.take.tracks.flatMap(\.segments) {
                #expect(SaverFixture.exists(fixture.package.url.appending(path: segment.file)))
            }
        }
    }

    @Test func thawIsCalledOnceWhateverHappens() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let projects = SaverFixture.projects(dir)

            // Saved, under the longest name a save takes (200 bytes of UTF-8).
            let longest = String(repeating: "é", count: 100)
            let saved = SaverFixture.Source(.success(fixture.snapshot))
            let result = try await ReplaySaver.save(from: saved, SaverFixture.request(dir, seconds: 3, name: longest))
            #expect(result.projectURL.lastPathComponent == longest + ".toma")
            #expect(saved.calls == ["freeze", "thaw"])

            // Nothing to save: `freeze()` threw, after it may have stopped pruning.
            let empty = SaverFixture.Source(.failure(.nothingToSave))
            await #expect(throws: ReplayError.nothingToSave) {
                try await ReplaySaver.save(from: empty, SaverFixture.request(dir, seconds: 3, name: "Empty"))
            }
            #expect(empty.calls == ["freeze", "thaw"])

            // No screen in the take.
            var withoutScreen = fixture.snapshot
            withoutScreen.take.tracks.removeAll(where: \.kind.isScreen)
            let noScreen = SaverFixture.Source(.success(withoutScreen))
            await #expect(throws: ReplayError.noScreen) {
                try await ReplaySaver.save(from: noScreen, SaverFixture.request(dir, seconds: 3, name: "No Screen"))
            }
            #expect(noScreen.calls == ["freeze", "thaw"])

            // A file that cannot be cloned, before the thaw.
            let clone = SaverFixture.Source(.success(fixture.snapshot))
            await #expect(throws: POSIXError(.EIO)) {
                try await ReplaySaver.save(
                    from: clone, SaverFixture.request(dir, seconds: 3, name: "Clone"), files: SaverFixture.failing { _ in true })
            }
            #expect(clone.calls == ["freeze", "thaw"])

            // A file that cannot be written after the thaw: something took the log's name in the hidden folder meanwhile.
            let late = SaverFixture.Source(.success(fixture.snapshot)) {
                for staging in SaverFixture.stagingFolders(in: projects) {
                    try? Data("{}".utf8).write(to: staging.appending(path: "edit-log.jsonl"))
                }
            }
            await #expect(throws: POSIXError(.EEXIST)) {
                try await ReplaySaver.save(from: late, SaverFixture.request(dir, seconds: 3, name: "Late"))
            }
            #expect(late.calls == ["freeze", "thaw"])

            #expect(SaverFixture.names(in: projects) == [longest + ".toma"])
        }
    }

    @Test func aNameThatIsNotOneIsRefusedBeforeAnything() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let source = SaverFixture.Source(.success(fixture.snapshot))
            let names = [
                "", ".hidden", "a/b", "a:b", " leading", "trailing ", "line\nbreak", "bell\u{7}", "nul\0",
                String(repeating: "x", count: 201), String(repeating: "é", count: 101),
                // Too long for a file name at all: refused before the rename would refuse it.
                String(repeating: "x", count: 300),
            ]
            for name in names {
                #expect(!ReplaySaver.isValidName(name), "\(name.debugDescription)")
                await #expect(throws: POSIXError(.EINVAL), "\(name.debugDescription)") {
                    try await ReplaySaver.save(from: source, SaverFixture.request(dir, seconds: 3, name: name))
                }
            }
            await #expect(throws: POSIXError(.EINVAL)) {
                try await ReplaySaver.save(from: source, SaverFixture.request(dir, seconds: 0))
            }
            // Nothing was frozen nor thawed, and nothing written.
            #expect(source.calls.isEmpty)
            #expect(SaverFixture.names(in: SaverFixture.projects(dir)).isEmpty)
            for name in [SaverFixture.name, "Demo 2", String(repeating: "x", count: 200), "Ñandú · copia"] {
                #expect(ReplaySaver.isValidName(name), "\(name)")
            }
        }
    }

    @Test func concurrentSavesTakeTurns() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            // A slow freeze: two saves that did not wait for each other would both freeze before either thaws.
            let source = SaverFixture.Source(.success(fixture.snapshot), freezeDelay: .milliseconds(200))
            async let first = ReplaySaver.save(from: source, SaverFixture.request(dir, seconds: 3))
            async let second = ReplaySaver.save(from: source, SaverFixture.request(dir, seconds: 3))
            let names = try await [first, second].map(\.projectURL.lastPathComponent).sorted()
            #expect(source.calls == ["freeze", "thaw", "freeze", "thaw"])
            #expect(names == [SaverFixture.name + " 2.toma", SaverFixture.name + ".toma"])
        }
    }

    @Test func liveSaveIsNeverRemoved() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let projects = SaverFixture.projects(dir)
            // In the middle of the save (at its thaw), the app opens and cleans up the projects folder.
            let seen = SaverFixture.Box<(staging: [String], removed: [URL])>(([], []))
            let source = SaverFixture.Source(.success(fixture.snapshot)) {
                let staging = SaverFixture.stagingFolders(in: projects).map(\.lastPathComponent)
                seen.value = (staging, ReplaySaver.removeAbandonedSaves(in: projects))
            }
            let result = try await ReplaySaver.save(from: source, SaverFixture.request(dir, seconds: 3))
            let (staging, removed) = seen.value
            #expect(staging.count == 1)
            #expect(removed.isEmpty)
            #expect(try LoadedProject.load(result.projectURL).take.status == .complete)
            // Its lock does not stay in the project.
            #expect(!SaverFixture.exists(result.projectURL.appending(path: ReplaySaver.lockName)))
            #expect(SaverFixture.names(in: projects) == [SaverFixture.name + ".toma"])
        }
    }

    @Test func abandonedSaveIsRemovedAndNeverAProject() async throws {
        try await withTemporaryDirectory { dir in
            let projects = SaverFixture.projects(dir)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let done = try await ReplaySaver.save(
                from: fixture.source, SaverFixture.request(dir, seconds: 3, name: "Done"))
            func staging() -> String { "." + UUID().uuidString + ReplaySaver.stagingSuffix }
            func lockURL(_ name: String) -> URL { projects.appending(path: name).appending(path: ReplaySaver.lockName) }
            let minutesAgo = Date(timeIntervalSinceNow: -120)

            // What a forced quit leaves in the middle of a save: the hidden folder, whole but for its rename, with its
            // lock file and nobody holding it (the kernel let go of it with the process).
            let crashed = staging()
            try FileManager.default.copyItem(at: done.projectURL, to: projects.appending(path: crashed))
            try Data("{}".utf8).write(to: lockURL(crashed))
            // One a crash cut between the folder and its lock, a while ago.
            let lockless = staging()
            try FileManager.default.copyItem(at: done.projectURL, to: projects.appending(path: lockless))
            try FileManager.default.setAttributes([.modificationDate: minutesAgo], ofItemAtPath: projects.appending(path: lockless).path)
            // A save that has just made its folder and not its lock yet.
            let starting = staging()
            try FileManager.default.createDirectory(at: projects.appending(path: starting), withIntermediateDirectories: false)
            // A save another holder of its lock is making (another process, or another save of this one): even old.
            let live = staging()
            try FileManager.default.copyItem(at: done.projectURL, to: projects.appending(path: live))
            let holder = open(lockURL(live).path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
            #expect(holder >= 0)
            try FileManager.default.setAttributes([.modificationDate: minutesAgo], ofItemAtPath: projects.appending(path: live).path)
            // Never a project, before they are removed.
            #expect(RecoveryScanner.scan(directory: projects).isEmpty)

            let others = [
                "." + UUID().uuidString + ".duplicating", ".Other", ".not-a-uuid" + ReplaySaver.stagingSuffix,
                UUID().uuidString + ReplaySaver.stagingSuffix,
            ]
            for name in others {
                try FileManager.default.createDirectory(at: projects.appending(path: name), withIntermediateDirectories: false)
            }
            let link = staging()
            let target = dir.appending(path: "Target", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: target.appending(path: "file"))
            try FileManager.default.createSymbolicLink(atPath: projects.appending(path: link).path, withDestinationPath: target.path)

            let removed = ReplaySaver.removeAbandonedSaves(in: projects)
            #expect(removed.map(\.lastPathComponent) == [crashed, lockless].sorted())
            #expect(SaverFixture.names(in: projects) == (others + [link, starting, live, "Done.toma"]).sorted())
            #expect(SaverFixture.names(in: target) == ["file"])
            #expect(try LoadedProject.load(done.projectURL).take.status == .complete)

            // Once its holder lets go (its process died), the save it was making is abandoned too.
            close(holder)
            #expect(ReplaySaver.removeAbandonedSaves(in: projects).map(\.lastPathComponent) == [live])
            #expect(SaverFixture.names(in: projects) == (others + [link, starting, "Done.toma"]).sorted())
            #expect(ReplaySaver.removeAbandonedSaves(in: dir.appending(path: "Nowhere")).isEmpty)
        }
    }

    /// A forced quit between a save's rename and its unlock leaves `.save.lock` in the saved project's root: it goes once
    /// its lock is free, and the project stays as it is.
    @Test func aStraySaveLockInASavedProjectGoesWhenItsLockIsFree() async throws {
        try await withTemporaryDirectory { dir in
            let projects = SaverFixture.projects(dir)
            let fixture = try await ReplayFixture(in: dir, seconds: 8)
            let done = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3, name: "Done"))
            let stray = done.projectURL.appending(path: ReplaySaver.lockName, directoryHint: .notDirectory)
            let holder = open(stray.path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
            #expect(holder >= 0)
            let before = SaverFixture.names(in: done.projectURL)

            #expect(ReplaySaver.removeAbandonedSaves(in: projects).isEmpty)
            #expect(SaverFixture.exists(stray))
            close(holder)
            #expect(ReplaySaver.removeAbandonedSaves(in: projects) == [stray])
            #expect(SaverFixture.names(in: done.projectURL) == before.filter { $0 != ReplaySaver.lockName })
            #expect(try LoadedProject.load(done.projectURL).take.status == .complete)
        }
    }

    @Test func prunedFirstSegmentsAreNotNeeded() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await ReplayFixture(in: dir, seconds: 8, pruned: 2)
            #expect(fixture.snapshot.take.tracks.allSatisfy { $0.segments.map(\.index) == [3, 4] })
            #expect(fixture.snapshot.shards.count == 2)
            #expect(!fixture.snapshot.carried.isEmpty)

            // The last 3 s: the scratch's segments 3 and 4, renumbered.
            let three = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 3))
            let project = try LoadedProject.load(three.projectURL)
            #expect(project.take.tracks.allSatisfy { $0.segments.map(\.index) == [1, 2] })

            // More than what is left: all of it, from the screen's first segment left, with the state of what was pruned.
            let all = try await ReplaySaver.save(from: fixture.source, SaverFixture.request(dir, seconds: 30, name: "All"))
            #expect(all.duration == .seconds(4))
            let whole = try LoadedProject.load(all.projectURL)
            let start = fixture.start.adding(seconds: 4)
            #expect(whole.take.tracks.allSatisfy { $0.segments.first?.startHostTime == start })
            let first = whole.events.prefix { $0.t == start }
            #expect(first.contains { if case .displayGeometry(1, _, _) = $0.kind { true } else { false } })
            #expect(first.contains {
                if case let .cursorImage(hash, _, _, _) = $0.kind { hash == fixture.secondCursorHash } else { false }
            })
            #expect(SaverFixture.exists(whole.package.cursorImageURL(take: "take-001", hash: fixture.secondCursorHash)))
            #expect(whole.take.cameraStyle == ReplayFixture.laterCameraStyle)
            let (_, document) = try EditSession.readDocument(all.projectURL, take: nil, context: SaverFixture.context(dir))
            #expect(document.sequence.first?.start == start)
            #expect(fixture.thawCount == 2)
        }
    }
}
