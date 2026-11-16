// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import Editing

// An import tried again after one whose move into `assets/` worked but whose folder sync failed finds the image there
// already: it syncs the folder before it says the image is in (final review A-M4, Task 15), or the `set` naming it would
// be durable while the image's entry in the folder might not be.

/// Which folders were synced, and whether the next sync fails.
private final class Syncs: @unchecked Sendable {
    var count = 0
    var failNext = false

    func sync(_ fd: Int32) throws {
        count += 1
        if failNext {
            failNext = false
            throw POSIXError(.EIO)
        }
        try DurableFile.fullSync(fd)
    }
}

@Test func aRetriedImportSyncsTheFolderItFindsTheImageIn() throws {
    try withTemporaryDirectory { dir in
        let package = ProjectPackage(url: dir.appending(path: "Fixture.toma", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        let image = dir.appending(path: "photo.png")
        try Data((0..<256).map { UInt8($0) }).write(to: image)
        // `assets/` exists already, so only the sync after the move is asked for on the first try.
        try FileManager.default.createDirectory(at: package.url.appending(path: "assets"), withIntermediateDirectories: false)

        let syncs = Syncs()
        syncs.failNext = true
        #expect(throws: AssetImport.Failure.self) { try AssetImport.place(image, into: package, syncFolder: syncs.sync) }
        #expect(syncs.count == 1)
        let placed = try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "assets").path)
        #expect(placed.count == 1 && placed[0].hasSuffix(".png"), "moved in, its folder not synced")

        let name = try AssetImport.place(image, into: package, syncFolder: syncs.sync)
        #expect(name == "assets/" + placed[0])
        #expect(syncs.count == 2, "the retry syncs the folder it found the image in")
    }
}
