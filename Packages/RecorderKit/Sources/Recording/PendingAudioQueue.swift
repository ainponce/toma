// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia

/// Real-time audio waiting for the encoder, oldest first.
///
/// Holds at most `capacitySeconds` of audio, measured in frames (`CMSampleBufferGetNumSamples`) at
/// the source sample rate, so a buffer without a usable duration still counts in full. The newest
/// buffer is always kept, even when it alone is longer than the capacity.
struct PendingAudioQueue {
    let capacityFrames: Int
    /// Frames in the queue.
    private(set) var frames = 0
    private var buffers: [CMSampleBuffer] = []

    init(capacitySeconds: Double, sampleRate: Double) {
        capacityFrames = Int((capacitySeconds * sampleRate).rounded())
    }

    var count: Int { buffers.count }
    var isEmpty: Bool { buffers.isEmpty }
    var first: CMSampleBuffer? { buffers.first }

    /// Adds `buffer` at the end, then drops the oldest buffers while the queue is over capacity.
    /// - Returns: The dropped buffers, oldest first.
    mutating func push(_ buffer: CMSampleBuffer) -> [CMSampleBuffer] {
        buffers.append(buffer)
        frames += CMSampleBufferGetNumSamples(buffer)
        var dropped: [CMSampleBuffer] = []
        while frames > capacityFrames, buffers.count > 1 {
            let oldest = buffers.removeFirst()
            frames -= CMSampleBufferGetNumSamples(oldest)
            dropped.append(oldest)
        }
        return dropped
    }

    mutating func popFirst() -> CMSampleBuffer? {
        guard !buffers.isEmpty else { return nil }
        let oldest = buffers.removeFirst()
        frames -= CMSampleBufferGetNumSamples(oldest)
        return oldest
    }

    /// Empties the queue. - Returns: What it held, oldest first.
    mutating func removeAll() -> [CMSampleBuffer] {
        defer {
            buffers.removeAll()
            frames = 0
        }
        return buffers
    }
}
