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
/// (`TrackFrameReader.trackLoadTimeout`) or a long decode never blocks the caller, on the main thread or any other; and
/// `latest(atSource:)`, for playback, never waits at all: a frame not decoded in time leaves the one before it. Meant for
/// one consumer, asking for the instants in the order scheduled: one asked for that is not the next scheduled drops the
/// ones before it (frames skipped, as playback does), or, if it is not scheduled at all, everything scheduled (a jump),
/// and is decoded first, on its own. An instant someone is waiting for is never dropped that way: only `reset()` drops it,
/// and wakes whoever waits for it to ask again. So a second caller asking at the same time slows the first one down but
/// never leaves it waiting for good. A caller can wait in a task (`frame(atSource:)`) or on a queue of its own
/// (`frame(atSource:completion:)`).
///
/// For scrubbing, `keyFrame(atSource:)` decodes the key frame at or before an instant alone, without the reader.
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
    /// Decodes the key frames of `keyFrame(atSource:)`; used by one caller at a time.
    private let keyFrames: Mutex<KeyFrameDecoder>

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
        /// The latest instant decoded, its entry taken or dropped or not, and its frame: what `latest(atSource:)` shows
        /// for a later instant not decoded in time.
        var newest: (time: HostTime, frame: CachedTexture?)?
        /// Callers waiting for an entry to be decoded, by a token of theirs, with the entry's `id`.
        var waiters: [Int: (entry: Int, waiter: Waiter)] = [:]
        var nextToken = 0

        /// The entry of instant `time`, the first one scheduled for it, after dropping those before it that nobody waits
        /// for (frames skipped); or, when `time` is not scheduled, a new entry for it, first in line, after dropping every
        /// entry nobody waits for (a jump). Returns its index. No entry anybody waits for is dropped here.
        mutating func entry(at time: HostTime) -> Int {
            let waited = Set(waiters.values.map(\.entry))
            let end = entries.firstIndex { $0.time == time } ?? entries.endIndex
            let dropped = Set(entries[..<end].filter { !waited.contains($0.id) }.map(\.id))
            entries.removeAll { dropped.contains($0.id) }
            if let found = entries.firstIndex(where: { $0.time == time }) { return found }
            entries.insert(Entry(id: nextID, time: time), at: 0)
            nextID += 1
            return 0
        }

        /// Takes the waiters of entry `id`.
        mutating func waiters(of id: Int) -> [Waiter] {
            let tokens = waiters.filter { $0.value.entry == id }.map(\.key)
            return tokens.compactMap { waiters.removeValue(forKey: $0)?.waiter }
        }

        /// The first entry not decoded yet, if there is room to decode it within `byteLimit`.
        func nextToDecode(byteLimit: Int) -> Int? {
            guard let index = entries.firstIndex(where: { $0.decoded == nil }), index < FramePrefetcher.maxFrames else { return nil }
            let bytesAhead = entries[..<index].reduce(0) { $0 + $1.bytes }
            return index == 0 || bytesAhead + frameBytes <= byteLimit ? index : nil
        }
    }

    /// Who waits for an entry, and how it is woken: to ask again.
    private enum Waiter {
        case task(CheckedContinuation<Void, any Error>)
        case callback(@Sendable () -> Void)

        func wake() {
            switch self {
            case let .task(continuation): continuation.resume()
            case let .callback(callback): callback()
            }
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
        keyFrames = Mutex(try KeyFrameDecoder(device: device))
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
    /// once it is; a caller waiting is woken and asks again.
    func reset() {
        let waiting = state.withLock { state in
            state.entries.removeAll()
            state.newest = nil
            defer { state.waiters.removeAll() }
            return state.waiters.values.map(\.waiter)
        }
        for waiter in waiting { waiter.wake() }
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
            let (step, waitFor) = state.withLock { state -> (Result<CachedTexture?, RenderError>?, Int) in
                // Instants scheduled before it were skipped, or it was not scheduled: they go.
                let index = state.entry(at: time)
                let entry = state.entries[index]
                guard let decoded = entry.decoded else { return (nil, entry.id) }
                state.entries.remove(at: index)
                return (decoded, entry.id)
            }
            decodeIfThereIsRoom()
            if let step { return try step.get() }
            try await waitForEntry(waitFor)
        }
    }

    /// `frame(atSource:)` for a caller that waits on a queue of its own rather than in a task: `completion` gets the frame,
    /// or why it could not be made a texture, once it is decoded (at once if it was decoded ahead), on the caller's thread
    /// or on this prefetcher's queue. Never blocks.
    func frame(atSource time: HostTime, completion: @escaping @Sendable (Result<CachedTexture?, RenderError>) -> Void) {
        let decoded = state.withLock { state -> Result<CachedTexture?, RenderError>? in
            let index = state.entry(at: time)
            let entry = state.entries[index]
            if let decoded = entry.decoded {
                state.entries.remove(at: index)
                return decoded
            }
            // Woken once it is decoded, or dropped by `reset()`: then it asks again.
            defer { state.nextToken += 1 }
            state.waiters[state.nextToken] = (entry.id, .callback { [self] in frame(atSource: time, completion: completion) })
            return nil
        }
        decodeIfThereIsRoom()
        if let decoded { completion(decoded) }
    }

    /// What `latest(atSource:)` finds.
    enum Latest {
        /// The frame at the instant (`nil` before the track's first readable frame), decoded in time.
        case onTime(CachedTexture?)
        /// The frame at the instant is not decoded yet: the latest frame decoded at an instant before it, and that
        /// instant (`nil` when none was).
        case late(previous: (time: HostTime, frame: CachedTexture?)?)
    }

    /// The frame at source instant `time` if it is decoded already, without ever waiting: for playback, which shows the
    /// frame before it when it is not (`latest(atSource:)`). Like `frame(atSource:)`, it drops the instants scheduled
    /// before it, or schedules it first when it was not (a jump); one not decoded yet stays scheduled, to be decoded.
    /// - Throws: `RenderError.textureCreationFailed` for a frame Core Video cannot make a texture of.
    func latestFrame(atSource time: HostTime) throws -> Latest {
        let latest = state.withLock { state -> Result<Latest, RenderError> in
            let index = state.entry(at: time)
            guard let decoded = state.entries[index].decoded else {
                return .success(.late(previous: state.newest.flatMap { $0.time < time ? $0 : nil }))
            }
            state.entries.remove(at: index)
            return decoded.map(Latest.onTime)
        }
        decodeIfThereIsRoom()
        return try latest.get()
    }

    /// The frame at source instant `time` while playing: the one decoded for it if it is, in time; otherwise the latest
    /// one decoded before it, which stays on screen (`nil` when there is none yet, or before the track's first readable
    /// frame). Never waits.
    /// - Throws: `RenderError.textureCreationFailed` for a frame Core Video cannot make a texture of.
    func latest(atSource time: HostTime) throws -> CachedTexture? {
        switch try latestFrame(atSource: time) {
        case let .onTime(frame): frame
        case let .late(previous): previous?.frame ?? nil
        }
    }

    /// For scrubbing: the key frame at or before source instant `time` of the segment that holds it, alone, decoded
    /// without the track's reader and without opening an `AVAssetReader` (`KeyFrameDecoder`), as a texture; `nil` in a
    /// gap, before the segment's first frame, or when it cannot be decoded. The last one is kept, so instants that show
    /// the same key frame decode nothing. Blocks while it loads the segment's track (`TrackFrameReader.media(at:)`, up to
    /// `TrackFrameReader.trackLoadTimeout`) and decodes: call it on a queue of the caller's own, never the main thread
    /// or a Swift concurrency thread.
    func keyFrame(atSource time: HostTime) -> CachedTexture? {
        // The segment's file, known already when it is one shown before: the reader, which may be busy decoding the exact
        // frame ahead (`schedule`), is not waited for.
        let known = keyFrames.withLock { $0.media(at: time) }
        guard let media = known ?? reader.media(at: time) else { return nil }
        return keyFrames.withLock { $0.keyFrame(at: time, of: media) }
    }

    /// How many key frames `keyFrame(atSource:)` decoded, for tests.
    var keyFramesDecoded: Int { keyFrames.withLock { $0.decodeCount } }

    /// Returns once entry `id` is decoded or dropped, or throws `CancellationError` if the task is cancelled first.
    private func waitForEntry(_ id: Int) async throws {
        let token = state.withLock { state in
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waits = state.withLock { state -> Bool in
                    guard !Task.isCancelled, let entry = state.entries.first(where: { $0.id == id }), entry.decoded == nil else {
                        return false
                    }
                    state.waiters[token] = (id, .task(continuation))
                    return true
                }
                if !waits {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume() }
                }
            }
        } onCancel: {
            if case let .task(continuation)? = state.withLock({ $0.waiters.removeValue(forKey: token) })?.waiter {
                continuation.resume(throwing: CancellationError())
            }
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
            let waiting = state.withLock { state -> [Waiter] in
                if case let .success(texture?) = decoded { state.lastDecoded = texture }
                if case let .success(texture) = decoded, state.newest.map({ $0.time <= next.time }) ?? true {
                    state.newest = (next.time, texture)
                }
                if bytes > 0 { state.frameBytes = bytes }
                // Dropped meanwhile (a jump): what was decoded goes.
                guard let index = state.entries.firstIndex(where: { $0.id == next.id }) else { return [] }
                state.entries[index].decoded = decoded
                state.entries[index].bytes = bytes
                return state.waiters(of: next.id)
            }
            for waiter in waiting { waiter.wake() }
        }
    }
}
