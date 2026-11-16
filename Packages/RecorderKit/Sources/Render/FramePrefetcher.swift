// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import Synchronization

/// Decodes the frames of one video track ahead of whoever draws them, on a queue of its own: the source instants it is
/// told it will be asked for (`schedule(_:)`), in that order, each the frame its `TrackFrameReader` gives for it (the
/// latest one at or before it), as textures. It decodes up to `maxFrames` instants ahead, the one asked for next among
/// them, and fewer when the distinct frames among them would take more than `maxBytes` (8 frames of 6K are about 650 MB);
/// taking a frame lets it go on.
///
/// The reader is asked for exactly the instants scheduled, one after the other in the order scheduled, as drawing them
/// frame by frame would ask it: it decodes the same frames, and records the same gaps (`TrackFrameReader.gaps`).
///
/// `frame(atSource:)` waits for its frame without holding a thread, so a track whose load hangs
/// (`TrackFrameReader.trackLoadTimeout`) or a long decode never blocks the caller, on the main thread or any other. Meant
/// for one consumer, asking for the instants in the order scheduled: one asked for that is not the next scheduled drops
/// the ones before it (frames skipped, as playback does), or, if it is not scheduled at all, everything scheduled (a jump),
/// and is decoded on its own.
final class FramePrefetcher: @unchecked Sendable {
    /// Instants decoded ahead at most, the one asked for next among them.
    static let maxFrames = 8
    /// Bytes of the distinct frames decoded ahead, at most: no frame is decoded that would pass it (but the next one asked
    /// for always is).
    static let maxBytes = 300 << 20

    let trackID: String
    /// `maxBytes`, or less for tests.
    private let byteLimit: Int
    private let reader: TrackFrameReader
    /// Its own, used only on `queue`.
    private let textureCache: CVMetalTextureCache
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private struct Entry {
        let id: Int
        let time: HostTime
        /// `nil` until it is decoded; then the frame at `time` (`nil` in it before the track's first readable frame), or
        /// why it could not be made a texture.
        var decoded: Result<CachedTexture?, RenderError>?
        /// Of a frame no entry before it holds; 0 otherwise.
        var bytes = 0
    }

    private struct State {
        /// In the order scheduled: the one asked for next first.
        var entries: [Entry] = []
        var nextID = 0
        /// A decoding job is queued or running on `queue`.
        var decoding = false
        /// The frame decoded last, kept so an instant showing the same frame shares its texture.
        var lastDecoded: CachedTexture?
        /// The bytes of the distinct frame decoded last: about what the next one takes.
        var frameBytes = 0
        /// Callers waiting for an entry to be decoded, by a token of theirs, with the entry's `id`.
        var waiters: [Int: (entry: Int, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var nextToken = 0

        /// The first entry not decoded yet, if there is room to decode it within `byteLimit`.
        func nextToDecode(byteLimit: Int) -> Int? {
            guard let index = entries.firstIndex(where: { $0.decoded == nil }), index < FramePrefetcher.maxFrames else { return nil }
            let bytesAhead = entries[..<index].reduce(0) { $0 + $1.bytes }
            return index == 0 || bytesAhead + frameBytes <= byteLimit ? index : nil
        }
    }

    /// Reads with `reader`, which nothing else should read while this does. `maxBytes`: `FramePrefetcher.maxBytes`, or
    /// less for tests.
    /// - Throws: `RenderError.metalResourceUnavailable` if Core Video cannot make a texture cache for `device`.
    init(reader: TrackFrameReader, device: any MTLDevice, maxBytes: Int = FramePrefetcher.maxBytes) throws {
        let usage = MTLTextureUsage.shaderRead.rawValue
        let attributes = [kCVMetalTextureUsage as String: NSNumber(value: usage)] as CFDictionary
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, attributes, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw RenderError.metalResourceUnavailable("prefetch texture cache (CVReturn \(status))")
        }
        self.reader = reader
        trackID = reader.trackID
        byteLimit = maxBytes
        textureCache = cache
        queue = DispatchQueue(label: "dev.toma.FramePrefetcher.\(reader.trackID)", qos: .userInitiated)
    }

    /// Adds `time` to the instants it will be asked for, after those scheduled already.
    func schedule(_ time: HostTime) {
        state.withLock { state in
            state.entries.append(Entry(id: state.nextID, time: time))
            state.nextID += 1
        }
        decodeIfThereIsRoom()
    }

    /// Drops every instant scheduled and every frame decoded ahead, as after a jump. A frame being decoded is dropped
    /// once it is; a caller waiting asks again.
    func reset() {
        let waiting = state.withLock { state in
            state.entries.removeAll()
            defer { state.waiters.removeAll() }
            return state.waiters.values.map(\.continuation)
        }
        for continuation in waiting { continuation.resume() }
    }

    /// How many instants are scheduled and not taken yet, and how many of them are decoded: for tests.
    var pending: (scheduled: Int, decoded: Int) {
        state.withLock { state in (state.entries.count, state.entries.count(where: { $0.decoded != nil })) }
    }

    /// The frame at source instant `time`, as `TrackFrameReader.pixelBuffer(at:)` gives it, as a texture; `nil` before the
    /// track's first readable frame. Waits, suspended, for it to be decoded: right away if it was decoded ahead.
    /// - Throws: `CancellationError` when the task waiting is cancelled, and `RenderError.textureCreationFailed` for a
    ///   frame Core Video cannot make a texture of.
    func frame(atSource time: HostTime) async throws -> CachedTexture? {
        while true {
            try Task.checkCancellation()
            let step = state.withLock { state -> Result<CachedTexture?, RenderError>? in
                // Instants scheduled before it were skipped, or it was not scheduled: they go.
                while let first = state.entries.first, first.time != time { state.entries.removeFirst() }
                if state.entries.isEmpty {
                    state.entries.append(Entry(id: state.nextID, time: time))
                    state.nextID += 1
                }
                guard let decoded = state.entries[0].decoded else { return nil }
                state.entries.removeFirst()
                return decoded
            }
            decodeIfThereIsRoom()
            if let step { return try step.get() }
            try await waitForTheFirstEntry()
        }
    }

    /// Returns once the entry first in line now is decoded or dropped, or throws `CancellationError` if the task is
    /// cancelled first.
    private func waitForTheFirstEntry() async throws {
        let token = state.withLock { state in
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waits = state.withLock { state -> Bool in
                    guard !Task.isCancelled, let first = state.entries.first, first.decoded == nil else { return false }
                    state.waiters[token] = (first.id, continuation)
                    return true
                }
                if !waits {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume() }
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: token) }?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Starts decoding on `queue` unless it is decoding already or there is nothing to decode or no room.
    private func decodeIfThereIsRoom() {
        let start = state.withLock { state in
            guard !state.decoding, state.nextToDecode(byteLimit: byteLimit) != nil else { return false }
            state.decoding = true
            return true
        }
        if start { queue.async { self.decodeAhead() } }
    }

    /// Decodes the entries in line, one after the other, while there is room. Runs on `queue`.
    private func decodeAhead() {
        while true {
            let next = state.withLock { [byteLimit] state -> (id: Int, time: HostTime, last: CachedTexture?)? in
                guard let index = state.nextToDecode(byteLimit: byteLimit) else {
                    state.decoding = false
                    return nil
                }
                return (state.entries[index].id, state.entries[index].time, state.lastDecoded)
            }
            guard let next else { return }
            // Blocks while the reader loads and decodes; nothing else waits on this queue.
            let pixelBuffer = reader.pixelBuffer(at: next.time)
            let decoded: Result<CachedTexture?, RenderError>
            var bytes = 0
            if let pixelBuffer {
                if let last = next.last, last.pixelBuffer === pixelBuffer {
                    decoded = .success(last)
                } else {
                    CVMetalTextureCacheFlush(textureCache, 0)
                    decoded = Result { () throws(RenderError) -> CachedTexture? in try CachedTexture(pixelBuffer, cache: textureCache) }
                    bytes = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
                }
            } else {
                decoded = .success(nil)
            }
            let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
                if case let .success(texture?) = decoded { state.lastDecoded = texture }
                if bytes > 0 { state.frameBytes = bytes }
                // Dropped meanwhile (a jump): what was decoded goes.
                guard let index = state.entries.firstIndex(where: { $0.id == next.id }) else { return [] }
                state.entries[index].decoded = decoded
                state.entries[index].bytes = bytes
                let tokens = state.waiters.filter { $0.value.entry == next.id }.map(\.key)
                return tokens.compactMap { state.waiters.removeValue(forKey: $0)?.continuation }
            }
            for continuation in waiting { continuation.resume() }
        }
    }
}
