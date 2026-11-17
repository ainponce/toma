// SPDX-License-Identifier: GPL-3.0-or-later

/// Work for the latest of a series of options, as a sheet's options change (the export sheet's GIF preview and estimate,
/// 1c design §7.3): the first options run at once; each later change runs `settle` after it, unless another change comes
/// first. A change cancels the work for the options before it, and `stop()`, when the sheet ends, cancels it for good.
///
/// Its owner keeps it, and the work it is given should hold the owner weakly: stopping then frees the owner (and what it
/// holds) as soon as the work notices it was cancelled, whatever the view that showed it does.
@MainActor
public final class SettlingWork<Request: Sendable> {
    /// How long a change waits for the next one before its work starts.
    public let settle: Duration
    /// The work was stopped: nothing runs any more.
    public private(set) var isStopped = false

    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    /// Some options ran already: the next ones wait to settle.
    private var started = false

    /// `sleep` waits, throwing when it is cancelled (tests give their own).
    public init(settle: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.settle = settle
        self.sleep = sleep
    }

    /// The options are now `request`: the work for those before is cancelled, and `work` runs for `request`, at once the
    /// first time and after `settle` from then on; for `nil` (no options to work for), nothing runs.
    public func run(for request: Request?, _ work: @escaping @MainActor (Request) async -> Void) {
        task?.cancel()
        task = nil
        guard !isStopped, let request else { return }
        let waits = started
        started = true
        let settle = settle, sleep = sleep
        task = Task {
            if waits {
                do { try await sleep(settle) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await work(request)
        }
    }

    /// The sheet ended: the work under way is cancelled, and none runs again.
    public func stop() {
        isStopped = true
        task?.cancel()
        task = nil
    }
}
