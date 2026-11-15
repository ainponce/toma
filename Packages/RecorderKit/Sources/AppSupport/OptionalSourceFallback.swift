// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A broken camera, microphone or system audio must not keep the screen from being recorded.
public enum OptionalSourceFallback {
    /// The kinds of the sources in `optional` whose own first start failed, so a take whose start threw `error` is
    /// recorded again without them. None when the take was stopped while starting (a cancellation): it is not retried.
    public static func failedOptionalKinds(after error: any Error, among optional: [StartTrackingSource]) -> Set<TrackKind> {
        guard !(error is CancellationError) else { return [] }
        return Set(optional.filter { $0.firstStartFailure != nil }.map(\.kind))
    }
}
