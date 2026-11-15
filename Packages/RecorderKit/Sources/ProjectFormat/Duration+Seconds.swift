// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch

extension Duration {
    /// The duration in seconds.
    package var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// The duration for a dispatch timer: whole nanoseconds, at least 1.
    package var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(max(1, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)))
    }
}
