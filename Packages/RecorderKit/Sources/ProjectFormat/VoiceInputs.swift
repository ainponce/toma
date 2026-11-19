// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The voice of one audio track without its noise (`soundIsolation-2`, phase 2 design §5.6), as the mix reads it from
/// the caches (plan decision 14): for each segment of the track that is heard, a CAF file (Float32 LPCM, mono, 48 kHz)
/// that holds exactly the timeline frames the segment's audio is heard over (`TrackAudio.spans`).
public struct CleanVoice: Equatable, Sendable {
    /// The file of each segment, by `SegmentRecord.file`.
    public var files: [String: URL]

    public init(files: [String: URL]) {
        self.files = files
    }
}

/// The loudness measure (`loudness-1`, phase 2 design §5.7) of one audio track over the whole take, as the mix reads it
/// from the caches (plan decision 15): the K-weighted energy of each 400 ms block, every 100 ms from the first frame of
/// each of its segments, the blocks of all its segments one after the other.
///
/// `dry` is the energy of the track as recorded, summed over its `channels`; `wet` that of its clean voice (mono) and
/// `cross` the sum over the channels of the clean voice times the dry, both only when every segment had its clean voice
/// when it was measured. With them, `Loudness.blocks(of:cleanup:mixChannels:)` gives the blocks of the track as the mix
/// plays it, at any cleanup.
public struct TrackLoudness: Equatable, Sendable {
    /// Channels of the track (1 or 2), which `dry` and `cross` are summed over.
    public var channels: Int
    public var dry: [Double]
    public var wet: [Double]?
    public var cross: [Double]?

    public init(channels: Int, dry: [Double], wet: [Double]?, cross: [Double]?) {
        self.channels = channels
        self.dry = dry
        self.wet = wet
        self.cross = cross
    }
}
