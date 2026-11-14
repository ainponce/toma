// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

private let utc = TimeZone(identifier: "UTC")!
private let app = AppInfo(name: "Tests", version: "0")

/// 2026-11-13 09:05:07 UTC.
private let date: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9, minute: 5, second: 7))!
}()

@Test func nameIsThePrefixAndTheDateAndTime() {
    #expect(ProjectFolder.baseName(prefix: "Recording", date: date, timeZone: utc) == "Recording 2026-11-13 09.05.07")
    #expect(ProjectFolder.baseName(prefix: "Grabación", date: date, timeZone: utc) == "Grabación 2026-11-13 09.05.07")
}

@Test func nameUsesTheGivenTimeZone() {
    let buenosAires = TimeZone(identifier: "America/Argentina/Buenos_Aires")!  // UTC−3, no daylight saving
    #expect(ProjectFolder.baseName(prefix: "Recording", date: date, timeZone: buenosAires) == "Recording 2026-11-13 06.05.07")
}

@Test func takenNamesGetTheNextNumber() throws {
    try withTemporaryDirectory { directory in
        let folder = directory.appendingPathComponent("Movies/Toma", isDirectory: true)  // created on first use
        let names = try (1...3).map { _ in
            try ProjectFolder.createPackage(in: folder, prefix: "Recording", app: app, now: date, timeZone: utc)
        }
        #expect(names.map(\.url.lastPathComponent) == [
            "Recording 2026-11-13 09.05.07.toma",
            "Recording 2026-11-13 09.05.07 2.toma",
            "Recording 2026-11-13 09.05.07 3.toma",
        ])
        for package in names {
            #expect(package.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(try LoadedProjectManifest.read(package).takes.isEmpty)
        }
    }
}

@Test func aFolderThatCannotBeCreatedThrows() throws {
    try withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("Movies", isDirectory: false)
        try Data().write(to: file)
        #expect(throws: (any Error).self) {
            try ProjectFolder.createPackage(
                in: file.appendingPathComponent("Toma", isDirectory: true), prefix: "Recording", app: app, now: date)
        }
    }
}

@Test func onlyAPackageWithNothingRecordedIsRemoved() throws {
    try withTemporaryDirectory { directory in
        let unused = try ProjectFolder.createPackage(in: directory, prefix: "Unused", app: app, now: date)
        try ProjectFolder.removeIfUnused(unused)
        #expect(!FileManager.default.fileExists(atPath: unused.url.path))

        // A take folder the manifest does not list: raw data may be in it.
        let withFiles = try ProjectFolder.createPackage(in: directory, prefix: "Files", app: app, now: date)
        try FileManager.default.createDirectory(at: withFiles.takeDirectory("take-001"), withIntermediateDirectories: false)
        try ProjectFolder.removeIfUnused(withFiles)
        #expect(FileManager.default.fileExists(atPath: withFiles.takeDirectory("take-001").path))

        let withTake = try ProjectFolder.createPackage(in: directory, prefix: "Take", app: app, now: date)
        try ManifestStore(package: withTake).update {
            $0.takes.append(TakeRecord(id: "take-001", status: .complete, startedAt: date, tracks: []))
        }
        try ProjectFolder.removeIfUnused(withTake)
        #expect(FileManager.default.fileExists(atPath: withTake.manifestURL.path))

        // Nothing says it is unused.
        let unreadable = try ProjectFolder.createPackage(in: directory, prefix: "Unreadable", app: app, now: date)
        try FileManager.default.removeItem(at: unreadable.manifestURL)
        #expect(throws: (any Error).self) { try ProjectFolder.removeIfUnused(unreadable) }
        #expect(FileManager.default.fileExists(atPath: unreadable.takesURL.path))
    }
}

@Test func defaultFolderIsTheAppNameInMovies() {
    let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    #expect(ProjectFolder.defaultURL(appName: "Toma").standardizedFileURL
        == movies.appendingPathComponent("Toma", isDirectory: true).standardizedFileURL)
}

/// The manifest a package holds on disk.
private enum LoadedProjectManifest {
    static func read(_ package: ProjectPackage) throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }
}
