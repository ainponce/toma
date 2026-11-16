// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// MARK: - When the state is written

@Test func autosaveWritesOnlyAStateThatChanged() {
    #expect(EditorStateAutosave.interval == .seconds(5))
    var autosave = EditorStateAutosave(restored: EditorState(playheadFrame: 10))
    #expect(autosave.due(EditorState(playheadFrame: 10)) == nil)
    #expect(autosave.due(EditorState(playheadFrame: 42)) == EditorState(playheadFrame: 42))
    // Written: the same state again is not.
    #expect(autosave.due(EditorState(playheadFrame: 42)) == nil)
    #expect(autosave.written == EditorState(playheadFrame: 42))
    let hidden = EditorState(playheadFrame: 42, panelVisible: false)
    #expect(autosave.due(hidden) == hidden)
    let moved = EditorState(windowFrame: Rect(x: 10, y: 20, width: 1200, height: 800), playheadFrame: 42, panelVisible: false)
    #expect(autosave.due(moved) == moved)
}

@Test func closingAlwaysWritesTheState() {
    var autosave = EditorStateAutosave(restored: EditorState(tab: "zoom"))
    // Unchanged too: the write marks the project as used (`ProjectCaches.removeUnused`).
    #expect(autosave.closing(EditorState(tab: "zoom")) == EditorState(tab: "zoom"))
    #expect(autosave.closing(EditorState(tab: "audio")) == EditorState(tab: "audio"))
    #expect(autosave.due(EditorState(tab: "audio")) == nil)
}

// MARK: - Where the window opens

/// The visible frame of a 1440 × 900 pt screen without its 25 pt menu bar, and one of 1920 × 1080 to its right.
private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)
private let external = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
private let minimum = CGSize(width: 1024, height: 680)

@Test func aSavedFrameOnAScreenIsKept() {
    #expect(EditorWindowPlacement.titleBarHeight == 28)
    #expect(EditorWindowPlacement.reachableWidth == 100)
    let saved = Rect(x: 100, y: 50, width: 1200, height: 800)
    #expect(EditorWindowPlacement.frame(restoring: saved, screens: [laptop], minimumSize: minimum) == CGRect(x: 100, y: 50, width: 1200, height: 800))
    // Its top at the top of the visible frame: the title bar is all on the screen.
    let top = Rect(x: 0, y: 75, width: 1440, height: 800)
    #expect(EditorWindowPlacement.frame(restoring: top, screens: [laptop], minimumSize: minimum) == CGRect(x: 0, y: 75, width: 1440, height: 800))
    #expect(EditorWindowPlacement.frame(restoring: nil, screens: [laptop], minimumSize: minimum) == nil)
}

@Test func aFrameWhoseTitleBarIsOnNoScreenOpensCentered() {
    // On a screen that is not connected any more.
    let gone = Rect(x: 2000, y: 100, width: 1200, height: 800)
    #expect(EditorWindowPlacement.frame(restoring: gone, screens: [laptop], minimumSize: minimum) == nil)
    #expect(EditorWindowPlacement.frame(restoring: gone, screens: [laptop, external], minimumSize: minimum) == CGRect(x: 2000, y: 100, width: 1200, height: 800))
    // Its title bar above the visible frame, under the menu bar.
    let high = Rect(x: 100, y: 200, width: 1200, height: 800)
    #expect(EditorWindowPlacement.frame(restoring: high, screens: [laptop], minimumSize: minimum) == nil)
    // 99 pt of the title bar on the screen are not enough; 100 are.
    let edge = Rect(x: 1341, y: 50, width: 1200, height: 800)
    #expect(EditorWindowPlacement.frame(restoring: edge, screens: [laptop], minimumSize: minimum) == nil)
    let reachable = Rect(x: 1340, y: 50, width: 1200, height: 800)
    #expect(EditorWindowPlacement.frame(restoring: reachable, screens: [laptop], minimumSize: minimum) == CGRect(x: 1340, y: 50, width: 1200, height: 800))
    #expect(EditorWindowPlacement.frame(restoring: reachable, screens: [], minimumSize: minimum) == nil)
}

@Test func aRestoredFrameFitsBetweenTheLeastSizeAndItsScreenKeepingItsTopLeft() {
    // Smaller than the least size: it grows down and to the right.
    let small = Rect(x: 100, y: 100, width: 800, height: 500)
    #expect(EditorWindowPlacement.frame(restoring: small, screens: [laptop], minimumSize: minimum) == CGRect(x: 100, y: -80, width: 1024, height: 680))
    // Larger than the screen it is on now (saved on a larger one): its size is the screen's.
    let large = Rect(x: 0, y: -200, width: 2000, height: 1075)
    #expect(EditorWindowPlacement.frame(restoring: large, screens: [laptop], minimumSize: minimum) == CGRect(x: 0, y: 0, width: 1440, height: 875))
    // Across two screens: the one with more of its title bar is its screen.
    let mostlyExternal = Rect(x: 1140, y: 0, width: 2000, height: 850)
    #expect(EditorWindowPlacement.frame(restoring: mostlyExternal, screens: [laptop, external], minimumSize: minimum) == CGRect(x: 1140, y: 0, width: 1920, height: 850))
    let mostlyLaptop = Rect(x: -400, y: 0, width: 2000, height: 850)
    #expect(EditorWindowPlacement.frame(restoring: mostlyLaptop, screens: [laptop, external], minimumSize: minimum) == CGRect(x: -400, y: 0, width: 1440, height: 850))
}

// MARK: - Where the state is

/// A take of 1 s of one display, in a new package `<name>.toma` of `formatVersion`.
@concurrent private func package(in dir: URL, name: String, formatVersion: Int) async throws -> LoadedProject {
    let base = HostTime(nanoseconds: 5_000_000_000_000)
    let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
    let frame = Rect(x: 0, y: 0, width: 640, height: 360)
    try await builder.addVideoTrack(
        id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
        segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
    try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
    return try builder.write()
}

@MainActor @Test func theStateIsInTheCachesTheSessionUses() async throws {
    try await withTemporaryDirectory { dir in
        let root = dir.appending(path: "Caches")
        let context = EditContext(
            app: AppInfo(name: "Toma", version: "0"), cachesRoot: root, defaultStyle: .toma, now: { Date() },
            makeID: { $0 + "00000001" })
        // Version 3 has its own id; version 2, the one derived from its manifest.
        for (name, version) in [("New", 3), ("Old", 2)] {
            let project = try await package(in: dir, name: name, formatVersion: version)
            let caches = try #require(EditorStateFile.caches(ofPackageAt: project.package.url, root: root))
            let session = try await EditSession.open(project.package.url, take: nil, context: context)
            #expect(caches.directory == session.caches.directory)
            #expect(caches.directory.deletingLastPathComponent().path == root.path)
            await session.close()
        }
        #expect(EditorStateFile.caches(ofPackageAt: dir.appending(path: "Missing.toma"), root: root) == nil)
    }
}

@Test func aManifestThatIsASymlinkIsNotFollowed() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await package(in: dir, name: "Linked", formatVersion: 3)
        let manifest = project.package.manifestURL
        let elsewhere = dir.appending(path: "manifest-elsewhere.json")
        try FileManager.default.moveItem(at: manifest, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: elsewhere)
        #expect(EditorStateFile.caches(ofPackageAt: project.package.url, root: dir.appending(path: "Caches")) == nil)
    }
}
