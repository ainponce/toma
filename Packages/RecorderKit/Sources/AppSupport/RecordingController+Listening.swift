// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension RecordingController {
    /// The microphone of the take that records, metered, to listen to (`MeteredSource.listen(_:)`: Follow the Voice,
    /// plan 3d decision 15), from the moment the take has one (while it starts) until it is closed; `nil` without a
    /// take or for a take without a microphone. Each take has its own, a restart's new one too: it is not observed, so
    /// read it again when `takeSerial` changes.
    public var microphoneSource: MeteredSource? {
        take?.microphoneMeter
    }
}
