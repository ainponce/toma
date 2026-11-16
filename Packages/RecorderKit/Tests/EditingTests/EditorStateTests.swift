// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// `EditorState()`, the window as a project opens the first time.
private func expectDefaults(_ state: EditorState, _ comment: Comment? = nil) {
    #expect(state == EditorState(), comment)
    #expect(state.panelVisible, comment)
    #expect(state.tab == "background", comment)
    #expect(state.timelineScale == nil, comment)
    #expect(state.windowFrame == nil, comment)
    #expect(state.playheadFrame == 0, comment)
    #expect(state.timelineOffset == 0, comment)
    #expect(!state.legacyBannerDismissed, comment)
}

/// Sets the modification date of `url` (a file or a folder) without following a symlink.
private func setModificationDate(_ url: URL, _ date: Date) throws {
    let seconds = date.timeIntervalSince1970
    var times = [
        timespec(tv_sec: Int(seconds), tv_nsec: 0),
        timespec(tv_sec: Int(seconds), tv_nsec: 0),
    ]
    guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
}

@Test func editorStateRoundTripsAndToleratesDamage() throws {
    try withTemporaryDirectory { dir in
        let caches = ProjectCaches(root: dir.appending(path: "Projects"), projectID: ProjectID.random())

        // No file (the folder is not even there): the defaults.
        expectDefaults(EditorState.load(caches), "no file")

        let state = EditorState(
            windowFrame: Rect(x: 120, y: 80, width: 1440, height: 900), playheadFrame: 1_234, timelineScale: 42.5,
            timelineOffset: 310, tab: "cursor", panelVisible: false, legacyBannerDismissed: true)
        state.save(caches)
        #expect(EditorState.load(caches) == state)
        // Saved over, the last one is read.
        var moved = state
        moved.playheadFrame = 99
        moved.timelineScale = nil
        moved.save(caches)
        #expect(EditorState.load(caches) == moved)

        // 10 random bytes.
        var generator = SystemRandomNumberGenerator()
        try Data((0..<10).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).write(to: caches.editorState)
        expectDefaults(EditorState.load(caches), "10 random bytes")

        for damaged in ["", "[]", "{\"tab\":", "null", "{\"panelVisible\":\"yes\",\"tab\":7,\"timelineScale\":-3}"] {
            try Data(damaged.utf8).write(to: caches.editorState)
            expectDefaults(EditorState.load(caches), "\(damaged)")
        }
        // A key this version does not know, from a later one, is ignored; the ones it knows are read.
        try Data("{\"playheadFrame\":7,\"tab\":\"zoom\",\"splitRatio\":0.4}".utf8).write(to: caches.editorState)
        #expect(EditorState.load(caches) == EditorState(playheadFrame: 7, tab: "zoom"))

        // A folder where the file should be gives the defaults, and saving does not throw.
        try FileManager.default.removeItem(at: caches.editorState)
        try FileManager.default.createDirectory(at: caches.editorState, withIntermediateDirectories: false)
        expectDefaults(EditorState.load(caches), "a folder")
        state.save(caches)
        // macOS emptied the caches folder: saving makes it again.
        try FileManager.default.removeItem(at: caches.directory)
        state.save(caches)
        #expect(EditorState.load(caches) == state)
    }
}

@Test func unusedCachesAreRemovedAfter30Days() throws {
    try withTemporaryDirectory { dir in
        let root = dir.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_794_773_523)
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

        /// A project's cache folder whose `editor-state.json` (none when `state` is `nil`) and folder were last
        /// modified `state` and `folder` days ago.
        func project(state: Double?, folder: Double) throws -> URL {
            let caches = ProjectCaches(root: root, projectID: ProjectID.random())
            try FileManager.default.createDirectory(at: caches.thumbnails, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: caches.thumbnails.appending(path: "take-001-display-1-seg-0001-0-56.png"))
            if let state {
                EditorState().save(caches)
                try setModificationDate(caches.editorState, daysAgo(state))
            }
            try setModificationDate(caches.directory, daysAgo(folder))
            return caches.directory
        }

        let old = try project(state: 31, folder: 31)
        let recent = try project(state: 29, folder: 31)
        let oldWithoutState = try project(state: nil, folder: 31)
        let recentWithoutState = try project(state: nil, folder: 29)
        // The folder changed more recently than its window state (a cache was made in it): it was used then.
        let folderTouched = try project(state: 40, folder: 29)
        // Not a project's cache folder: left alone, however old.
        let other = root.appending(path: "notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try setModificationDate(other, daysAgo(90))
        // A link named as a project, to an old folder elsewhere: neither is removed.
        let elsewhere = dir.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try setModificationDate(elsewhere, daysAgo(90))
        let link = root.appending(path: ProjectID.random())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        try setModificationDate(link, daysAgo(90))

        ProjectCaches.removeUnused(root: root, now: now)

        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
        #expect(!exists(old))
        #expect(exists(recent))
        #expect(!exists(oldWithoutState))
        #expect(exists(recentWithoutState))
        #expect(exists(folderTouched))
        #expect(exists(other))
        #expect(exists(link) && exists(elsewhere))

        // A shorter age, and a root that is not there, which changes nothing.
        ProjectCaches.removeUnused(olderThan: 28 * 86_400, root: root, now: now)
        #expect(!exists(recent) && !exists(recentWithoutState) && !exists(folderTouched))
        #expect(exists(other) && exists(link) && exists(elsewhere))
        ProjectCaches.removeUnused(root: dir.appending(path: "Missing"), now: now)
    }
}
