// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import Darwin
import Synchronization

/// Interleaved Float32 frames from one writer to one reader, without locks (design §7.7): the preview's feeder writes
/// the mix ahead into it, and the audio node reads it on the audio thread, which must never wait.
///
/// The frames keep their place in time. Frame `n` written goes out as the `n`th frame read, and a read of frames not
/// written yet gives silence for them and counts them as read: the reader never waits and never falls behind. A writer
/// behind the reader (it fell behind and the reader went on with silence) skips to it (`skip(to:)`), so the frames it
/// writes next go out where they belong, and the sound keeps time with what has been read.
///
/// A seek while the output goes on swaps what it plays without stopping it (`swap(after:)`): the frames from a little
/// past where reading is belong to another run, written from there; the reader fades the old frames out over
/// `fadeFrames` from where it is when it sees the swap, gives silence up to the new run and fades that in over as many.
///
/// The read position only grows (every frame read, silence included); the write position too, but at a swap, which
/// moves it to where the new run starts. The writer
/// writes into frames the reader has read, up to `capacityFrames` ahead of it, and publishes them by moving
/// `writePosition` on (release); the reader reads up to that (acquire) and publishes what it read by moving
/// `readPosition` on (release), which the writer reads (acquire) before it writes into them again. Unchecked
/// `Sendable`: the storage is shared, and those two positions keep each frame to one side at a time.
public final class AudioRingBuffer: @unchecked Sendable {
    /// Where reading stood when the reader last read, and the host time it was given for that reading (in
    /// `mach_absolute_time` ticks): the frames read before it, and when the first of the frames it read goes out.
    struct Reading: Equatable {
        var framesBefore: Int
        var hostTime: UInt64
    }

    let capacityFrames: Int
    let channels: Int

    private let storage: UnsafeMutablePointer<Float>
    private let read = Atomic<Int>(0)
    private let written = Atomic<Int>(0)
    /// `Reading` of the last read: the frames before it and its host time (0: none yet).
    private let reading = Atomic(WordPair(first: 0, second: 0))
    /// Where the run of the last swap starts (−1: none), and, the reader's own, where it began to fade the frames before
    /// it out and the swap that was for (both −1 before the first).
    private let swapped = Atomic(-1)
    private let fade = Atomic(WordPair(first: UInt(bitPattern: -1), second: UInt(bitPattern: -1)))

    /// A ring of `capacityFrames` frames of `channels` channels, empty.
    /// - Precondition: both are positive.
    public init(capacityFrames: Int, channels: Int) {
        precondition(capacityFrames > 0 && channels > 0, "AudioRingBuffer: \(capacityFrames) frames of \(channels) channels")
        self.capacityFrames = capacityFrames
        self.channels = channels
        storage = .allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// Writes the whole frames of `samples` (interleaved) that fit, from `writePosition` on, and returns how many it
    /// wrote. Only the writer calls it.
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let position = written.load(ordering: .relaxed)
        let free = capacityFrames - max(0, position - read.load(ordering: .acquiring))
        let frames = min(samples.count / channels, free)
        guard frames > 0, let source = samples.baseAddress else { return 0 }
        runs(frames, at: position) { offset, sample, count in (storage + offset).update(from: source + sample, count: count) }
        written.store(position + frames, ordering: .releasing)
        return frames
    }

    /// Fills `buffer` (interleaved, whole frames) with the next frames, silence for any not written yet, and returns how
    /// many frames it gave: all that fit in `buffer`. Only the reader calls it.
    public func read(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        let frames = buffer.count / channels
        guard let destination = buffer.baseAddress else { return frames }
        consume(frames, hostTime: mach_absolute_time()) { offset, frame, count in
            (destination + frame * channels).update(from: storage + offset, count: count * channels)
        } silence: { frame, count in
            (destination + frame * channels).update(repeating: 0, count: count * channels)
        } scale: { frame, gain in
            for c in 0..<channels { destination[frame * channels + c] *= gain }
        }
        return frames
    }

    /// Empties the ring: both positions back to 0, no swap. Only while neither side is reading or writing.
    public func reset() {
        read.store(0, ordering: .sequentiallyConsistent)
        written.store(0, ordering: .sequentiallyConsistent)
        reading.store(WordPair(first: 0, second: 0), ordering: .sequentiallyConsistent)
        swapped.store(-1, ordering: .sequentiallyConsistent)
        fade.store(WordPair(first: UInt(bitPattern: -1), second: UInt(bitPattern: -1)), ordering: .sequentiallyConsistent)
    }

    // MARK: - For the player

    /// 4 ms at 48 kHz: the fades of a swap, as long as those between two clips (`EditedMix`).
    static let fadeFrames = 192

    /// Starts another run `margin` frames past where reading is, and returns that position, where the writer writes it
    /// from: the frames written past it are dropped, those not written before it are silence, and the reader fades out
    /// what it plays before it and fades the new run in (see the type). Only while nothing else writes.
    /// - Precondition: `margin` is from 0 to `capacityFrames`, and at least the frames of one read, so a read under
    ///   way never reaches the new run.
    func swap(after margin: Int) -> Int {
        precondition(margin >= 0 && margin <= capacityFrames, "AudioRingBuffer: a swap \(margin) frames ahead")
        let reader = read.load(ordering: .acquiring)
        let start = reader + margin
        let from = written.load(ordering: .relaxed)
        let first = max(from, reader)
        if start > first {
            runs(start - first, at: first) { offset, _, count in (storage + offset).update(repeating: 0, count: count) }
        }
        written.store(start, ordering: .releasing)
        swapped.store(start, ordering: .releasing)
        return start
    }

    /// The frames read so far, silence included.
    var readPosition: Int { read.load(ordering: .acquiring) }
    /// The frames written so far, the silence of `skip(to:)` included.
    var writePosition: Int { written.load(ordering: .acquiring) }
    /// The frames written that have not been read.
    var availableFrames: Int { max(0, writePosition - readPosition) }
    /// The last reading: where reading stood and its host time; host time 0 before the first.
    var lastRead: Reading {
        let pair = reading.load(ordering: .acquiring)
        return Reading(framesBefore: Int(pair.first), hostTime: UInt64(pair.second))
    }

    /// Moves `writePosition` on to `position`, with silence in the frames it skips that can still be read. Only the
    /// writer calls it: once the reader has gone past `writePosition`, to write next where the reader is (or a little
    /// after it, to have the frames written before it gets there).
    /// - Precondition: `position` is at most `capacityFrames` past `readPosition`.
    func skip(to position: Int) {
        let from = written.load(ordering: .relaxed)
        guard position > from else { return }
        let reader = read.load(ordering: .acquiring)
        precondition(position - reader <= capacityFrames, "AudioRingBuffer: skipping to \(position), \(position - reader) frames ahead")
        let first = max(from, reader)
        if position > first {
            runs(position - first, at: first) { offset, _, count in (storage + offset).update(repeating: 0, count: count) }
        }
        written.store(position, ordering: .releasing)
    }

    /// Fills the node's `list` (one buffer per channel, or one interleaved buffer) with `frames` frames, as
    /// `read(into:)` does, noting `hostTime` as the reading's. Neither allocates nor locks: the audio thread calls it.
    func read(into list: UnsafeMutableAudioBufferListPointer, frames: Int, hostTime: UInt64) {
        let channels = channels
        let interleaved = list.count == 1 && Int(list[0].mNumberChannels) == channels
        let storage = storage
        consume(frames, hostTime: hostTime) { offset, frame, count in
            if interleaved {
                guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                (data + frame * channels).update(from: storage + offset, count: count * channels)
                return
            }
            for (c, buffer) in list.enumerated() where c < channels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<count { data[frame + i] = storage[offset + i * channels + c] }
            }
        } silence: { frame, count in
            for buffer in list {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let perFrame = interleaved ? channels : 1
                (data + frame * perFrame).update(repeating: 0, count: count * perFrame)
            }
        } scale: { frame, gain in
            for buffer in list {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let perFrame = interleaved ? channels : 1
                for c in 0..<perFrame { data[frame * perFrame + c] *= gain }
            }
        }
    }

    /// The gain of the frame at `position` around a swap: fading out from `fadingOutFrom` (from 191/192 down to 0), 0 up
    /// to the new run's start `runFrom`, fading in from there (from 0 up to 191/192), 1 after.
    private static func gain(at position: Int, fadingOutFrom fadingOut: Int, runFrom start: Int) -> Float {
        if position >= start {
            let into = position - start
            return into < fadeFrames ? Float(into) / Float(fadeFrames) : 1
        }
        let into = position - fadingOut
        return into < fadeFrames ? Float(fadeFrames - 1 - into) / Float(fadeFrames) : 0
    }

    // MARK: - Positions in the storage

    /// Calls `body(offset, sample, count)` for the one or two runs of samples that the `frames` frames from `position`
    /// take in the storage: from `offset` in it, from `sample` of the frames, `count` samples.
    private func runs(_ frames: Int, at position: Int, _ body: (_ offset: Int, _ sample: Int, _ count: Int) -> Void) {
        let start = position % capacityFrames
        let first = min(frames, capacityFrames - start)
        body(start * channels, 0, first * channels)
        if frames > first { body(0, first * channels, (frames - first) * channels) }
    }

    /// Reads the next `frames` frames: `give(offset, frame, count)` for the one or two runs of them that were written
    /// (from sample `offset` of the storage, frame `frame` of them, `count` frames), `silence(frame, count)` for those
    /// that were not, and `scale(frame, gain)` for each in the fades and the silence of a swap; then moves
    /// `readPosition` on by all of them and notes the reading with `hostTime`.
    private func consume(
        _ frames: Int, hostTime: UInt64, give: (_ offset: Int, _ frame: Int, _ count: Int) -> Void,
        silence: (_ frame: Int, _ count: Int) -> Void, scale: (_ frame: Int, _ gain: Float) -> Void
    ) {
        let position = read.load(ordering: .relaxed)
        // The swap first: what it wrote, the position included, comes with it.
        let start = swapped.load(ordering: .acquiring)
        var shape = fade.load(ordering: .relaxed)
        if Int(bitPattern: shape.second) != start {
            // A swap not seen before: the frames before its run fade out from here.
            shape = WordPair(first: UInt(bitPattern: position), second: UInt(bitPattern: start))
            fade.store(shape, ordering: .relaxed)
        }
        let available = min(frames, max(0, written.load(ordering: .acquiring) - position))
        if available > 0 {
            runs(available, at: position) { offset, sample, count in give(offset, sample / channels, count / channels) }
        }
        if frames > available { silence(available, frames - available) }
        if start >= 0 {
            let fadingFrom = Int(bitPattern: shape.first)
            let from = max(position, fadingFrom), to = min(position + frames, start + Self.fadeFrames)
            if from < to {
                for frame in from..<to {
                    let gain = Self.gain(at: frame, fadingOutFrom: fadingFrom, runFrom: start)
                    if gain != 1 { scale(frame - position, gain) }
                }
            }
        }
        read.store(position + frames, ordering: .releasing)
        reading.store(WordPair(first: UInt(position), second: UInt(hostTime)), ordering: .releasing)
    }
}
