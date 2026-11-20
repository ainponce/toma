// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A stand-in for task S1's `ShareError` (plan 5a), with only the case `ShareHistory` throws, so task S2 builds while S1
/// is written alongside it. When the two branches meet, S1's file replaces this one whole: its `ShareError` has this case.
public enum ShareError: Error, Equatable, Sendable {
    /// The package's `shares.json` cannot be read, so it is never written.
    case historyUnreadable
}
