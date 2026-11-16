// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Library
import ProjectFormat
import RecorderKitTestSupport

/// What the tests of this file share.
private enum Stores {
    /// `count` bytes that are never JSON: the first is not UTF-8, the rest come from a fixed seed.
    static func garbage(_ count: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0xFF, count: count)
        for i in 1..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 56)
        }
        return Data(bytes)
    }

    /// The copies set aside next to `url`: `<name>.damaged-<yyyyMMdd-HHmmss>`, `-2`, `-3`…
    static func setAside(next url: URL) throws -> [URL] {
        let prefix = url.lastPathComponent + ".damaged-"
        return try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(prefix) }.sorted()
            .map { url.deletingLastPathComponent().appending(path: $0, directoryHint: .notDirectory) }
    }

    /// A summary of every field, with `state` and `place`.
    static func summary(_ number: UInt64, state: ProjectState, place: Place) -> ProjectSummary {
        ProjectSummary(
            identity: PackageIdentity(volume: "8C2F6A1E-0B3D-4E0F-9A51-0C1D2E3F4A5B", file: 5_130_000 + number),
            path: "/Users/someone/Movies/Toma/Clientes/Demo \(number).toma", name: "Demo \(number)", place: place,
            recordedAt: Date(timeIntervalSince1970: 1_794_700_000 + Double(number)), outputSeconds: 134.25 + Double(number),
            aspect: .portrait, hasCamera: number.isMultiple(of: 2), formatVersion: 3, documentVersion: 2, state: state,
            size: 1_234_567_890, manifest: FileSignature(size: 2_048, modified: 1_794_700_000_123_456_789),
            edit: FileSignature(size: 9_000, modified: 1_794_700_001_000_000_000),
            log: FileSignature(size: 120, modified: 1_794_700_002_000_000_007), thumbnailKey: "ab12cd34",
            lastSeen: Date(timeIntervalSince1970: 1_794_800_000))
    }

    /// The `library.json` of design §13.4, with a bookmark that is base64.
    static let designExample = """
        {
          "favorites" : [ "8C2F6A1E-…:5130042" ],
          "lastOpened" : { "8C2F6A1E-…:5130042" : "2026-11-16T14:02:11Z" },
          "places" : [ { "added" : "2026-11-16T10:00:00Z", "bookmark" : "Ym9va21hcms=", "path" : "/Volumes/Trabajo/Cliente.toma" } ],
          "trashOrigins" : { "8C2F6A1E-…:5130977" : { "bookmark" : "Ym9va21hcms=", "path" : "/Users/…/Movies/Toma/Clientes" } },
          "version" : 1
        }
        """

    /// `data` as a JSON value, to compare two encodings of one object.
    static func object(_ data: Data) throws -> NSObject {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSObject)
    }
}

@Test func damagedOrNewerRecordsAreSetAside() async throws {
    let newer = Data(#"{"favorites": ["V:1"], "future": {"x": 1}, "version": 2}"#.utf8)
    for (name, bytes, isNewer) in [("damaged", Stores.garbage(4_096), false), ("newer", newer, true)] {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "library.json", directoryHint: .notDirectory)
            try bytes.write(to: url)

            let loaded = LibraryRecords.load(from: url)
            #expect(loaded.favorites.isEmpty && loaded.lastOpened.isEmpty && loaded.places.isEmpty, "\(name)")
            #expect(loaded.trashOrigins.isEmpty, "\(name)")
            #expect(loaded.version == (isNewer ? 2 : 1), "\(name)")
            // A copy, and the file itself as it was: nothing was written yet.
            let aside = try Stores.setAside(next: url)
            #expect(aside.count == 1, "\(name)")
            let stamp = try #require(aside.first?.lastPathComponent.dropFirst("library.json.damaged-".count))
            #expect(stamp.count == 15 && stamp.allSatisfy { $0.isNumber || $0 == "-" }, "\(name): \(stamp)")
            #expect(try Data(contentsOf: try #require(aside.first)) == bytes, "\(name)")
            #expect(try Data(contentsOf: url) == bytes, "\(name)")

            let store = LibraryRecordsStore(url: url)
            await store.update { $0.favorites.insert("V:7") }
            #expect(await store.records.favorites == ["V:7"], "\(name)")
            await store.flush()
            if isNewer {
                // A newer app's records stay as they are.
                #expect(try Data(contentsOf: url) == bytes, "\(name)")
            } else {
                #expect(LibraryRecords.load(from: url).favorites == ["V:7"], "\(name)")
            }
            // The same bytes are set aside once, however many times they are loaded.
            #expect(try Stores.setAside(next: url) == aside, "\(name)")
        }
    }
}

@Test func indexAndRecordsRoundTripAndTolerateDamage() throws {
    try withTemporaryDirectory { dir in
        // The index: every state and every place.
        let states: [ProjectState] = [
            .normal, .unfinished, .needsRepair("manifest.json: File too large"), .newerVersion, .readOnlyVolume,
            .inTrash(since: Date(timeIntervalSince1970: 1_794_750_000)), .unavailable(.diskNotConnected("Trabajo")),
            .unavailable(.notFound),
        ]
        let places: [Place] = [.projectsFolder(subfolder: ""), .projectsFolder(subfolder: "Clientes/2026"), .trash, .elsewhere]
        let index = LibraryIndex(
            version: 1,
            projects: states.enumerated().map { number, state in
                Stores.summary(UInt64(number), state: state, place: places[number % places.count])
            } + [
                ProjectSummary(
                    identity: PackageIdentity(volume: "V", file: 1), path: "/x/Bare.toma", name: "Bare", place: .elsewhere,
                    hasCamera: false, state: .unavailable(.notFound), lastSeen: Date(timeIntervalSince1970: 0))
            ])
        let indexURL = dir.appending(path: "index.json", directoryHint: .notDirectory)
        try DurableFile.writeAtomically(try index.encoded(), to: indexURL)
        #expect(LibraryIndex.load(from: indexURL) == index)
        let indexObject = try #require(try JSONSerialization.jsonObject(with: try index.encoded()) as? [String: Any])
        #expect(Set(indexObject.keys) == ["projects", "version"])
        #expect(indexObject["version"] as? Int == 1)

        // Damaged, missing or of a newer version: an empty index, which the scan fills again.
        let empty = LibraryIndex(version: 1, projects: [])
        try Stores.garbage(10_000).write(to: indexURL)
        #expect(LibraryIndex.load(from: indexURL) == empty)
        try Data(#"{"projects": [], "version": 2}"#.utf8).write(to: indexURL)
        #expect(LibraryIndex.load(from: indexURL) == empty)
        #expect(LibraryIndex.load(from: dir.appending(path: "missing.json")) == empty)

        // The records.
        let records = LibraryRecords(
            version: 1, favorites: ["V:1", "V:2", "W:3"],
            lastOpened: ["V:1": Date(timeIntervalSince1970: 1_794_760_000), "W:9": Date(timeIntervalSince1970: 1_794_000_000)],
            places: [
                OtherPlace(
                    added: Date(timeIntervalSince1970: 1_794_700_000), bookmark: Data([1, 2, 3]), path: "/Volumes/Trabajo/A.toma")
            ],
            trashOrigins: [
                "V:2": TrashOrigin(bookmark: Data([4, 5]), path: "/Users/someone/Movies/Toma/Clientes"),
                "V:5": TrashOrigin(path: "/Users/someone/Movies/Toma"),
            ])
        let recordsURL = dir.appending(path: "library.json", directoryHint: .notDirectory)
        try DurableFile.writeAtomically(try records.encoded(), to: recordsURL)
        #expect(LibraryRecords.load(from: recordsURL) == records)
        // The same records are the same bytes: favorites in order.
        #expect(try records.encoded() == (try LibraryRecords.load(from: recordsURL).encoded()))
        #expect(LibraryRecords.load(from: dir.appending(path: "missing.json")) == LibraryRecords())
        try Stores.garbage(512).write(to: recordsURL)
        #expect(LibraryRecords.load(from: recordsURL) == LibraryRecords())

        // The example of design §13.4.
        let example = try ProjectJSON.decoder().decode(LibraryRecords.self, from: Data(Stores.designExample.utf8))
        #expect(example.version == 1)
        #expect(example.favorites == ["8C2F6A1E-…:5130042"])
        #expect(example.lastOpened == ["8C2F6A1E-…:5130042": try Date("2026-11-16T14:02:11Z", strategy: .iso8601)])
        #expect(
            example.places == [
                OtherPlace(
                    added: try Date("2026-11-16T10:00:00Z", strategy: .iso8601), bookmark: Data("bookmark".utf8),
                    path: "/Volumes/Trabajo/Cliente.toma")
            ])
        #expect(
            example.trashOrigins == [
                "8C2F6A1E-…:5130977": TrashOrigin(bookmark: Data("bookmark".utf8), path: "/Users/…/Movies/Toma/Clientes")
            ])
        #expect(try Stores.object(try example.encoded()) == (try Stores.object(Data(Stores.designExample.utf8))))

        // Where they live (design §13.4).
        #expect(LibraryRecords.defaultURL.path.hasSuffix("/Library/Application Support/Toma/Library/library.json"))
        #expect(LibraryIndex.defaultURL.path.hasSuffix("/Library/Caches/dev.toma.Toma/Library/index.json"))
    }
}

@Test func writerKeepsTheLastWithinTwoSeconds() async throws {
    try await withTemporaryDirectory { dir in
        // Its folder is made when it is first written.
        let url = dir.appending(path: "Library/out.json", directoryHint: .notDirectory)
        let writer = DebouncedWriter(url: url)
        let clock = ContinuousClock()
        let start = clock.now
        for i in 0..<10 {
            writer.write(Data("\(i)".utf8))
            try await Task.sleep(for: .milliseconds(10))
        }
        // The first write waits its 2 s.
        let exists = { FileManager.default.fileExists(atPath: url.path) }
        if start.duration(to: clock.now) < .milliseconds(1_900) { #expect(!exists()) }
        #expect(await eventually(timeout: .seconds(10)) { exists() })
        #expect(start.duration(to: clock.now) >= .seconds(2))
        #expect(try Data(contentsOf: url) == Data("9".utf8))
        // Once: no other write follows.
        let written = try SystemFileSystem().stat(url).fileID
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(try SystemFileSystem().stat(url).fileID == written)
        #expect(try Data(contentsOf: url) == Data("9".utf8))

        // `flush` writes it at once.
        writer.write(Data("10".utf8))
        await writer.flush()
        #expect(try Data(contentsOf: url) == Data("10".utf8))

        // From many threads at once, one of them wins, whole.
        DispatchQueue.concurrentPerform(iterations: 100) { i in writer.write(Data("thread \(i)".utf8)) }
        await writer.flush()
        let last = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect((0..<100).map { "thread \($0)" }.contains(last), "\(last)")
        // Nothing is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["out.json"])
    }
}

@Test func recordsStoreUpdatesAndPersists() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appending(path: "Application Support/Toma/Library/library.json", directoryHint: .notDirectory)
        let store = LibraryRecordsStore(url: url)
        #expect(await store.records == LibraryRecords())

        let opened = Date(timeIntervalSince1970: 1_794_760_000)
        await store.update { records in
            records.favorites.insert("V:1")
            records.lastOpened["V:1"] = opened
            records.places.append(OtherPlace(added: opened, bookmark: Data([9]), path: "/Volumes/Trabajo/A.toma"))
            records.trashOrigins["V:2"] = TrashOrigin(path: "/Users/someone/Movies/Toma/Clientes")
        }
        // Many changes at once, from many tasks: none is lost.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { await store.update { $0.favorites.insert("W:\(i)") } }
            }
        }
        let expected = await store.records
        #expect(expected.favorites.count == 51)
        #expect(expected.lastOpened == ["V:1": opened])
        await store.flush()

        let other = LibraryRecordsStore(url: url)
        #expect(await other.records == expected)
        #expect(LibraryRecords.load(from: url) == expected)
        // Nothing was set aside: the file was its own.
        let aside = try Stores.setAside(next: url)
        #expect(aside.isEmpty)
    }
}
