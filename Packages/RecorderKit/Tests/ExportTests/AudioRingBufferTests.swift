// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
@testable import Export
import Foundation
import Testing

/// Runs `body` on a thread of its own, so a test that spins waiting on another thread never holds one of Swift's
/// cooperative pool.
private func onAThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}

/// One thread writes 1 000 000 stereo frames, in pieces of every size, into a ring of 4 096 while another reads them,
/// never more than are there: the reader gets the very sequence written.
@Test func ringBufferDeliversInOrderUnderConcurrency() async throws {
    let total = 1_000_000, channels = 2
    let ring = AudioRingBuffer(capacityFrames: 4_096, channels: channels)
    // Frame i is (i, −i): exact in Float up to 2²⁴.
    let written = (0..<total).flatMap { [Float($0), -Float($0)] }
    async let writer: Int = onAThread {
        var frame = 0, piece = 1
        while frame < total {
            let count = min(piece, total - frame)
            let taken = written.withUnsafeBufferPointer {
                ring.write(UnsafeBufferPointer(rebasing: $0[(frame * channels)..<((frame + count) * channels)]))
            }
            frame += taken
            piece = piece % 1_500 + 7
            if taken == 0 { sched_yield() }
        }
        return frame
    }
    async let reader: (read: [Float], whole: Bool) = onAThread {
        var read: [Float] = []
        // Whether every read gave as many frames as it was asked for.
        var whole = true
        read.reserveCapacity(total * channels)
        var piece = 1
        var buffer = [Float](repeating: .nan, count: 2_000 * channels)
        while read.count < total * channels {
            let count = min(piece, ring.availableFrames, total - read.count / channels)
            piece = piece % 1_900 + 11
            guard count > 0 else {
                sched_yield()
                continue
            }
            let given = buffer.withUnsafeMutableBufferPointer { ring.read(into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * channels)])) }
            whole = whole && given == count
            read += buffer[..<(count * channels)]
        }
        return (read, whole)
    }
    let (wrote, (read, whole)) = await (writer, reader)
    #expect(wrote == total && whole)
    #expect(read == written)
}

/// Reading more than there is gives what there is, then silence: 100 frames written and 4 096 read gives 4 096, the
/// first 100 as written and the rest 0.
@Test func underrunGivesSilence() {
    let ring = AudioRingBuffer(capacityFrames: 8_192, channels: 1)
    let written = (1...100).map(Float.init)
    #expect(written.withUnsafeBufferPointer { ring.write($0) } == 100)
    var buffer = [Float](repeating: .nan, count: 4_096)
    #expect(buffer.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 4_096)
    #expect(Array(buffer[..<100]) == written)
    #expect(buffer[100...].allSatisfy { $0 == 0 })
}

/// A full ring takes only what fits, and gives it back in order; `reset` empties it.
@Test func aFullRingTakesWhatFits() {
    let ring = AudioRingBuffer(capacityFrames: 1_000, channels: 2)
    let written = (0..<3_000).map(Float.init)
    #expect(written.withUnsafeBufferPointer { ring.write($0) } == 1_000)
    #expect(ring.availableFrames == 1_000)
    #expect(written.withUnsafeBufferPointer { ring.write($0) } == 0)
    var buffer = [Float](repeating: .nan, count: 600)
    #expect(buffer.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 300)
    #expect(buffer == Array(written[..<600]))
    // Past the end of its storage, the frames go on from its start.
    #expect(written.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[2_000...])) } == 300)
    var rest = [Float](repeating: .nan, count: 2_000)
    #expect(rest.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 1_000)
    #expect(rest == Array(written[600..<2_000]) + Array(written[2_000..<2_600]))
    ring.reset()
    #expect(ring.availableFrames == 0 && ring.readPosition == 0)
}

/// The ring keeps its frames in time: a frame's place is fixed by its position from the start, and silence read for a
/// frame not written yet counts as that frame. So the writer, once the reader has gone past it, skips to the reader
/// (`skip(to:)`, silence up to there), and the frames it writes then are read where they belong.
@Test func aWriterBehindTheReaderSkipsToIt() {
    let ring = AudioRingBuffer(capacityFrames: 64, channels: 1)
    let ones = [Float](repeating: 1, count: 10)
    #expect(ones.withUnsafeBufferPointer { ring.write($0) } == 10)
    var buffer = [Float](repeating: .nan, count: 30)
    #expect(buffer.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 30)
    #expect(ring.readPosition == 30 && ring.writePosition == 10 && ring.availableFrames == 0)
    // Silence for 5 frames past the reader, then frames 35 to 39.
    ring.skip(to: 35)
    let twos = [Float](repeating: 2, count: 5)
    #expect(twos.withUnsafeBufferPointer { ring.write($0) } == 5)
    var after = [Float](repeating: .nan, count: 12)
    #expect(after.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 12)
    #expect(after == [0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 0, 0])
}

/// The ring hands the node's buffers their frames one channel per buffer, and notes where its reading stood and when.
@Test func theNodeReadsOneChannelPerBuffer() {
    let ring = AudioRingBuffer(capacityFrames: 64, channels: 2)
    let written: [Float] = [1, -1, 2, -2, 3, -3]
    #expect(written.withUnsafeBufferPointer { ring.write($0) } == 3)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 5), right = UnsafeMutablePointer<Float>.allocate(capacity: 5)
    defer { left.deallocate(); right.deallocate() }
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 20, mData: left)
    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 20, mData: right)
    ring.read(into: list, frames: 5, hostTime: 1_234)
    #expect(Array(UnsafeBufferPointer(start: left, count: 5)) == [1, 2, 3, 0, 0])
    #expect(Array(UnsafeBufferPointer(start: right, count: 5)) == [-1, -2, -3, 0, 0])
    #expect(ring.lastRead == AudioRingBuffer.Reading(framesBefore: 0, hostTime: 1_234))
    ring.read(into: list, frames: 2, hostTime: 5_678)
    #expect(ring.lastRead == AudioRingBuffer.Reading(framesBefore: 5, hostTime: 5_678) && ring.readPosition == 7)
}
