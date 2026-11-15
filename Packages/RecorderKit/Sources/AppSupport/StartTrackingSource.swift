// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import ProjectFormat
import Recording
import Synchronization

/// A capture source that remembers how its first `start` ended, and forwards everything else to `base`.
/// It lets the app tell a take that could not start because of this source from one that failed for
/// another reason: the coordinator rethrows a source's error without saying which source it was.
public final class StartTrackingSource: CaptureSource {
    private enum FirstStart {
        case pending
        case started
        case failed(any Error)
    }

    public let base: any CaptureSource
    private let firstStart = Mutex(FirstStart.pending)

    public init(_ base: any CaptureSource) {
        self.base = base
    }

    public var trackID: String { base.trackID }
    public var kind: TrackKind { base.kind }
    public var media: TrackMedia { base.media }
    public var sourceInfo: TrackSource { base.sourceInfo }
    public var activeDeviceUniqueID: String? { base.activeDeviceUniqueID }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        do {
            try await base.start(on: queue, sink: sink)
            firstStart.withLock { if case .pending = $0 { $0 = .started } }
        } catch {
            firstStart.withLock { if case .pending = $0 { $0 = .failed(error) } }
            throw error
        }
    }

    public func stop() async {
        await base.stop()
    }

    /// The error the first `start` threw, unless it was a cancellation (the take was stopped while it
    /// started). `nil` if it has not been started, or started fine.
    public var firstStartFailure: (any Error)? {
        firstStart.withLock { state in
            guard case .failed(let error) = state, !(error is CancellationError) else { return nil }
            return error
        }
    }
}
