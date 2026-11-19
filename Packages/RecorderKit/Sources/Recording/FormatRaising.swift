// SPDX-License-Identifier: GPL-3.0-or-later

/// An input recorder that writes what only version 4 of the package defines (`keyPress` lines): before its first such
/// line of a take it calls the raise it was given, which moves the package to 4 (`ManifestStore.raiseFormatVersion(to:)`).
/// `RecordingCoordinator` gives it before `start(log:)`, to the input and to each recorder of a `CompositeInputRecorder`.
/// A take where it writes no such line leaves the package at 3.
public protocol FormatRaising: AnyObject, Sendable {
    /// What to call, once a take, before the first line that needs version 4; if it throws, the recorder writes no such
    /// line for the rest of the take. Kept until `stop()`.
    func setFormatRaiser(_ raise: @escaping @Sendable () throws -> Void)
}
