// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where a take's audio track has a voice (`ducking-1`, plan 3c decision 8): what is not silence (`SilenceFinder`) of the
/// track, inside the spans where the track is heard. Found by `VoiceActivityFinder`, kept in the analysis caches, read by
/// the mix; the mix never looks for the voice itself.
public struct VoiceActivity: Equatable, Sendable {
    /// Host time of each stretch with voice: in order, apart from one another.
    public var spans: [Range<HostTime>]

    public init(spans: [Range<HostTime>]) {
        self.spans = spans
    }
}
