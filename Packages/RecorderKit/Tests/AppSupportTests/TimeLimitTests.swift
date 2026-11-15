// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import RecorderKitTestSupport
import Testing

@Suite struct TimeLimitTests {
    @Test func anOperationWithinTheLimitGivesWhatItGives() async throws {
        #expect(try await withTimeLimit(.seconds(5)) { 42 } == 42)
        await #expect(throws: POSIXError(.EIO)) {
            try await withTimeLimit(.seconds(5)) { () async throws -> Int in throw POSIXError(.EIO) }
        }
    }

    @Test func anOperationThatNeverReturnsIsGivenUpAtTheLimit() async throws {
        let call = NeverReturningCall()
        defer { call.release() }
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: TimeLimitExceeded(limit: .milliseconds(200))) {
            try await withTimeLimit(.milliseconds(200)) { () async -> Int in
                await call.wait()
                return 1
            }
        }
        let waited = clock.now - started
        #expect(waited >= .milliseconds(200) && waited < .seconds(2), "\(waited)")
        // Left behind, cancelled.
        #expect(await eventually { call.wasCancelled })
    }

    @Test func aCancelledCallerStopsWaitingAtOnce() async throws {
        let call = NeverReturningCall()
        defer { call.release() }
        let clock = ContinuousClock()
        let started = clock.now
        let waiting = Task {
            try await withTimeLimit(.seconds(60)) { () async -> Int in
                await call.wait()
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(clock.now - started < .seconds(5))
        #expect(await eventually { call.wasCancelled })
    }
}
