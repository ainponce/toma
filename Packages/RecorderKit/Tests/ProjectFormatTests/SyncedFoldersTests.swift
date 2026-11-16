// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing

@Test func syncedFoldersAreICloudDriveAndTheFileProviders() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    // Whether or not the item exists yet, and in any case.
    #expect(SyncedFolders.contains(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/nope/x.toma")))
    #expect(SyncedFolders.contains(home.appending(path: "Library/CloudStorage/Dropbox/x.toma")))
    #expect(SyncedFolders.contains(home.appending(path: "library/cloudstorage/Dropbox/x.toma")))
    #expect(SyncedFolders.contains(home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)))
    // A folder whose name only starts the same is not one of them.
    #expect(!SyncedFolders.contains(home.appending(path: "Library/CloudStorageOld/x.toma")))
    #expect(!SyncedFolders.contains(FileManager.default.temporaryDirectory.appending(path: "nuevo/x.toma")))
}
