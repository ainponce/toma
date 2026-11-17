// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Runs `body` on a thread of its own and waits for it without holding a thread of Swift's cooperative pool.
///
/// For test code that blocks: decoding (`AVAssetReader.copyNextSampleBuffer`, `TrackFrameReader`, drawing a take with
/// `FrameRenderer`), waiting for the GPU, rendering a mix. Every test target runs in one process, in parallel, on one
/// pool as wide as the machine has cores: tests that block it starve the others' `eventually`, pings and time limits,
/// and many of them at once starve AVFoundation's own reads and hang the whole run (`make test` once hung for 5 hours).
///
/// `body` checks nothing itself: an expectation off the test's task would not be the test's. It throws, or returns
/// what the test checks.
public func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}
