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
    /// The user's pause: returns once nothing is recorded. `RecordingError.notRecording` unless recording or paused.
    func pause() async throws
    /// Ends the user's pause. `RecordingError.notRecording` unless recording or paused.
    func resume() async throws
    /// Marks this moment of the take and returns it. `RecordingError.notRecording` unless recording (not paused).
    @discardableResult func addMarker() async throws -> HostTime
    /// The camera looks like `style` from now on; written once the take records, if it is not paused. A take without
    /// a camera writes nothing. `RecordingError.notRecording` unless recording or paused (also while it starts).
    func setCameraStyle(_ style: CameraStyle) async throws
}

extension RecordingCoordinator: TakeRecording {}
