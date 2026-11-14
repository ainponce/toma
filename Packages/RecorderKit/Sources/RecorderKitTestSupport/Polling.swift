// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Polls `condition` until it holds or `timeout` passes.
public nonisolated(nonsending) func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// The readable duration of the movie at `url`, polled until it reaches `target` or `timeout` passes.
/// A movie that is still being written (or that AVFoundation cannot open yet) reads as 0.
public func readableDuration(of url: URL, reaching target: Double, timeout: Duration = .seconds(5)) async -> Double {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var seconds = 0.0
    while true {
        seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        if seconds >= target || clock.now >= deadline { return seconds }
        try? await Task.sleep(for: .milliseconds(50))
    }
}
