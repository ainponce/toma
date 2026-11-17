// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Library
import Synchronization

/// What the library's operations are told of the app at launch, when no library window exists: whether a take is
/// recorded (the finishing of deletions pauses meanwhile), and nothing open, since no action that asks about a project
/// runs from here.
final class LaunchLibraryState: LibraryAppState {
    private let recording = Mutex(false)

    func setRecording(_ isRecording: Bool) {
        recording.withLock { $0 = isRecording }
    }

    func isRecording() -> Bool { recording.withLock { $0 } }
    func isOpenHere(_ url: URL) -> Bool { false }
    func holdsEditLock(_ url: URL) -> Bool { false }
    func hasUnsavedChanges(_ url: URL) -> Bool { false }
    func close(_ url: URL) async -> Bool { true }
}
