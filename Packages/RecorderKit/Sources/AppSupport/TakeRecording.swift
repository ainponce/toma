// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Recording

/// One take as `RecordingController` drives it: `RecordingCoordinator` in the app, a wrapper of one in tests.
public protocol TakeRecording: AnyObject, Sendable {
    /// What the user should hear about, in order. Finishes when the take is closed or fails to start.
    var warnings: AsyncStream<RecordingWarning> { get }
    /// `handler` is called once if the take stops by itself (the disk is full), once it is closed.
    func setOnAutoStop(_ handler: @escaping @Sendable (TakeRecord, (any Error)?) -> Void) async
    /// Starts recording and returns the take's ID.
    func start() async throws -> String
    /// Closes the take, waiting for a `start()` in progress first, and returns it.
    func stop() async throws -> TakeRecord
}

extension RecordingCoordinator: TakeRecording {}
