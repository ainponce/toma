// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Synchronization

/// The process's slots for work that holds a thread waiting on AVFoundation's decoding: pulling an `AVAssetReader`
/// (`copyNextSampleBuffer`), an export's loop that pulls its readers, an offline render fed by one. At most `width` such
/// jobs run at once; the others wait for a slot without holding any thread.
///
/// Why a bound: each sample a reader gives is made ready on a serial queue of that reader
/// (`com.apple.coremedia.boss.makedataready.shared`) that runs on GCD's constrained pool, and that block waits
/// (`FigReadSchedulerExpediteRequest`) for the file read, which runs on another queue of the same pool
/// (`com.apple.coremedia.readscheduler…reads`). The pool has `kern.wq_max_constrained_threads` threads in a process (75 on
/// a 15-core Mac, never fewer than 64). Once that many readers are making data ready at once, every thread of the pool
/// waits for a read that no thread is left to run, and the process hangs for good at 0 % CPU (`sample` says "Dispatch
/// Thread Soft Limit: 75 reached", with that many `makedataready` threads and none on a `readscheduler` queue). Waiting
/// off Swift's cooperative pool does not prevent it, whatever threads pull the readers: only bounding how many are pulled
/// at once does. A 40-line program pulling 250 to 400 readers at once, each on a serial queue of its own, hangs that way
/// one time in two.
public final class DecodingSlots: Sendable {
    /// The process's slots, for everything that decodes: 8. A job pulls a few readers at once at most (an export, one per
    /// track it reads), so 8 jobs stay far below the smallest pool; more decoding at once than that does not end sooner.
    public static let shared = DecodingSlots(width: 8)

    /// How many jobs hold a slot at most.
    public let width: Int

    private struct State {
        /// Jobs holding a slot.
        var running = 0
        var nextTicket: UInt64 = 0
        /// Jobs waiting for a slot, first come first served.
        var waiting: [(ticket: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    }

    private let state = Mutex(State())

    public init(width: Int) {
        precondition(width > 0, "DecodingSlots: width \(width)")
        self.width = width
    }

    /// Runs `body` on a thread of its own (a serial queue labelled `label`) once a slot is free, holding the slot until
    /// `body` returns, and waits for it without holding a thread of Swift's cooperative pool.
    /// - Throws: what `body` throws, or `CancellationError` if the task is cancelled while it waits for a slot (`body`
    ///   then never runs). A task already cancelled that finds a slot free runs `body`, which sees the cancellation in
    ///   its own way.
    public func run<T: Sendable>(
        label: String = "dev.toma.Decoding", _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withSlot {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue(label: label, qos: .userInitiated).async {
                    continuation.resume(with: Result(catching: body))
                }
            }
        }
    }

    /// `body`, called once a slot is free and holding it until it returns or throws: for work that blocks a queue of its
    /// own (an export's loop) and is waited for in `body`.
    /// - Throws: what `body` throws, or `CancellationError` if the task is cancelled while it waits for a slot (`body`
    ///   is then not called).
    public func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    /// Jobs waiting for a slot now.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    /// Takes a slot, waiting for one if none is free. Whether one is free and, if not, the place in the queue are decided
    /// in one step, so a slot freed meanwhile is never missed; a cancellation handled before that step is seen by it
    /// (`Task.isCancelled`), one handled after it finds the job in the queue.
    private func acquire() async throws {
        let ticket = state.withLock { state in
            state.nextTicket += 1
            return state.nextTicket
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let granted: Bool? = state.withLock { state in
                    if state.running < width {
                        state.running += 1
                        return true
                    }
                    if Task.isCancelled { return false }
                    state.waiting.append((ticket, continuation))
                    return nil
                }
                switch granted {
                case true?: continuation.resume()
                case false?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiting.firstIndex { $0.ticket == ticket }.map { state.waiting.remove(at: $0).continuation }
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Frees a slot: it goes straight to the job that has waited longest, if one does.
    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard !state.waiting.isEmpty else {
                state.running -= 1
                return nil
            }
            return state.waiting.removeFirst().continuation
        }
        next?.resume()
    }
}
