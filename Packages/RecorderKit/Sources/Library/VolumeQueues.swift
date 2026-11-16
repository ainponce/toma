// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// The library scanner's serial queues and how it notices a slow disk (design §6.8, "Discos lentos"): one access to a
/// disk at a time, reads before sizes, sizes only while nothing is being recorded, and `.waiting(volume:)` once an
/// access takes longer than `LibraryScanner.slowAccess`. Nothing here holds the scanner: a job does, while it waits.
final class VolumeQueues: Sendable {
    private let isRecording: @Sendable () -> Bool
    private let onUpdate: @Sendable (LibraryUpdate) -> Void
    private let state = Mutex(State())
    /// Where slow accesses are noticed while they last.
    private let watchdog = DispatchQueue(label: "dev.toma.Toma.LibraryScanner.watchdog", qos: .utility)
    /// Where `.waiting` and `.waitingEnded` are told, in the order they happened.
    private let notices = DispatchQueue(label: "dev.toma.Toma.LibraryScanner.notices", qos: .utility)

    private struct State {
        var queues: [String: VolumeQueue] = [:]
        /// The disks, by name, that said `.waiting` and not `.waitingEnded` yet.
        var waiting: Set<String> = []
    }

    init(isRecording: @escaping @Sendable () -> Bool, onUpdate: @escaping @Sendable (LibraryUpdate) -> Void) {
        self.isRecording = isRecording
        self.onUpdate = onUpdate
    }

    /// The queue of `key`, made the first time: its waits say `name`; only a volume's queue (`endsWaiting`) ends them.
    func queue(key: String, name: String?, endsWaiting: Bool) -> VolumeQueue {
        state.withLock { state in
            if let queue = state.queues[key] { return queue }
            let queue = VolumeQueue(label: key, name: name, endsWaiting: endsWaiting)
            state.queues[key] = queue
            return queue
        }
    }

    /// Queues `job`, a read, after the reads queued before it and before any size.
    func enqueue(on queue: VolumeQueue, _ job: @escaping @Sendable () -> Void) {
        queue.pending.withLock { $0.reads.append(job) }
        startDraining(queue)
    }

    /// Queues `job`, the size of `identity`, after every read and the sizes queued before it, unless one for `identity`
    /// is waiting already.
    func enqueueSize(of identity: PackageIdentity, on queue: VolumeQueue, _ job: @escaping @Sendable () -> Void) {
        let added = queue.pending.withLock { pending in
            guard pending.sizeKeys.insert(identity).inserted else { return false }
            pending.sizes.append((identity, job))
            return true
        }
        if added { startDraining(queue) }
    }

    private func startDraining(_ queue: VolumeQueue) {
        let start = queue.pending.withLock { pending in
            guard !pending.isDraining else { return false }
            pending.isDraining = true
            return true
        }
        if start { queue.queue.async { self.drain(queue) } }
    }

    /// Runs the jobs of `queue`, reads first, until none is left or only sizes are and something is being recorded
    /// (then it asks again every `LibraryScanner.recordingRecheck`). An idle queue ends its disk's wait.
    private func drain(_ queue: VolumeQueue) {
        enum Next {
            case job(@Sendable () -> Void)
            case sizes
            case idle
        }
        while true {
            let next = queue.pending.withLock { pending -> Next in
                if !pending.reads.isEmpty { return .job(pending.reads.removeFirst()) }
                if pending.sizes.isEmpty {
                    pending.isDraining = false
                    return .idle
                }
                return .sizes
            }
            switch next {
            case .job(let job):
                job()
            case .idle:
                endWaiting(queue)
                return
            case .sizes:
                if isRecording() {
                    let (paused, recheck) = queue.pending.withLock { pending -> (Bool, Bool) in
                        guard pending.reads.isEmpty else { return (false, false) }
                        pending.isDraining = false
                        defer { pending.isRecheckScheduled = true }
                        return (true, !pending.isRecheckScheduled)
                    }
                    guard paused else { continue }
                    if recheck {
                        queue.queue.asyncAfter(deadline: .now() + LibraryScanner.recordingRecheck.dispatchInterval) {
                            queue.pending.withLock { $0.isRecheckScheduled = false }
                            self.startDraining(queue)
                        }
                    }
                    endWaiting(queue)
                    return
                }
                let job = queue.pending.withLock { pending -> (@Sendable () -> Void)? in
                    guard !pending.sizes.isEmpty else { return nil }
                    let (identity, job) = pending.sizes.removeFirst()
                    pending.sizeKeys.remove(identity)
                    return job
                }
                job?()
            }
        }
    }

    /// Runs `body`, an access to the disk of `queue`, timing it: past `slowAccess` (while it lasts, if the disk's name
    /// is known, or when it ends) the disk is `.waiting`; one that ends sooner ends the wait.
    func timed<T>(_ queue: VolumeQueue, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let arm = queue.pending.withLock { pending -> Bool in
            pending.accesses += 1
            pending.access = (pending.accesses, start)
            guard queue.name != nil, !pending.isCheckArmed else { return false }
            pending.isCheckArmed = true
            return true
        }
        if arm { armCheck(queue, from: start) }
        defer {
            queue.pending.withLock { $0.access = nil }
            if start.duration(to: .now) >= LibraryScanner.slowAccess {
                startWaiting(named: queue.name)
            } else {
                endWaiting(queue)
            }
        }
        return try body()
    }

    /// Looks, `slowAccess` after `start`, at the access under way on `queue`.
    private func armCheck(_ queue: VolumeQueue, from start: ContinuousClock.Instant) {
        let delay = max(.zero, LibraryScanner.slowAccess - start.duration(to: .now))
        watchdog.asyncAfter(deadline: .now() + delay.dispatchInterval) {
            enum Verdict {
                case slow
                case later(ContinuousClock.Instant)
                case done
            }
            let verdict = queue.pending.withLock { pending -> Verdict in
                guard let access = pending.access else {
                    pending.isCheckArmed = false
                    return .done
                }
                guard access.start.duration(to: .now) >= LibraryScanner.slowAccess else { return .later(access.start) }
                pending.isCheckArmed = false
                return .slow
            }
            switch verdict {
            case .slow: self.startWaiting(named: queue.name)
            case .later(let start): self.armCheck(queue, from: start)
            case .done: break
            }
        }
    }

    func startWaiting(named name: String?) {
        guard let name else { return }
        state.withLock { state in
            guard state.waiting.insert(name).inserted else { return }
            notices.async { self.onUpdate(.waiting(volume: name)) }
        }
    }

    /// Ends the wait of `queue`'s disk, if it is a volume's queue (finding a volume never ends it: the volume's queue
    /// goes on with the same disk).
    private func endWaiting(_ queue: VolumeQueue) {
        if queue.endsWaiting { endWaiting(named: queue.name) }
    }

    func endWaiting(named name: String?) {
        guard let name else { return }
        state.withLock { state in
            guard state.waiting.remove(name) != nil else { return }
            notices.async { self.onUpdate(.waitingEnded(volume: name)) }
        }
    }
}

/// A serial queue for one volume or synced location (or for finding volumes before their work goes to theirs): one
/// access to that disk at a time, reads before sizes.
final class VolumeQueue: Sendable {
    struct Pending {
        var reads: [@Sendable () -> Void] = []
        var sizes: [(PackageIdentity, @Sendable () -> Void)] = []
        var sizeKeys: Set<PackageIdentity> = []
        var isDraining = false
        var isRecheckScheduled = false
        /// The access under way, by number, and when it began.
        var access: (number: Int, start: ContinuousClock.Instant)?
        var accesses = 0
        /// A check of the access under way is due.
        var isCheckArmed = false
    }

    /// The name `.waiting` says, if known.
    let name: String?
    /// A volume's queue ends the wait of its disk; a queue that finds volumes does not.
    let endsWaiting: Bool
    let queue: DispatchQueue
    let pending = Mutex(Pending())

    init(label: String, name: String?, endsWaiting: Bool) {
        self.name = name
        self.endsWaiting = endsWaiting
        queue = DispatchQueue(label: "dev.toma.Toma.LibraryScanner." + label, qos: .utility)
    }
}

/// `base`, with every access timed on `queue`; the volume of the one URL `resolved` names is answered without asking
/// the disk again.
struct TimedFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    let queues: VolumeQueues
    let queue: VolumeQueue
    var resolved: (path: String, volume: VolumeInfo)?

    /// `body`, another access to the same disk (one that does not go through a file system, as `readDocument`), timed.
    func timed<T>(_ body: () throws -> T) rethrows -> T {
        try queues.timed(queue, body)
    }

    func list(_ directory: URL) throws -> [URL] {
        try timed { try base.list(directory) }
    }

    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat {
        try timed { try base.stat(url, withAddedDate: withAddedDate) }
    }

    func volume(of url: URL) throws -> VolumeInfo {
        if let resolved, url.standardizedFileURL.path == resolved.path { return resolved.volume }
        return try timed { try base.volume(of: url) }
    }

    func read(_ url: URL, maxBytes: Int) throws -> Data {
        try timed { try base.read(url, maxBytes: maxBytes) }
    }

    func allocatedSize(of package: URL) throws -> Int64 {
        try timed { try base.allocatedSize(of: package) }
    }

    func freeSpace(of url: URL) throws -> Int64 {
        try timed { try base.freeSpace(of: url) }
    }
}
