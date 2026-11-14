// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the helpers of this target throw where a test would record an issue: the target does not import
/// `Testing`, so a helper never calls `#expect` or `#require`.
public enum TestSupportError: Error {
    /// A value the helper needs is not there.
    case missing(String)
    /// A check of the helper failed.
    case failed(String)
}

/// `value`, or `TestSupportError.missing(what)` when it is `nil`.
public func unwrap<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw TestSupportError.missing(what) }
    return value
}

/// A fresh, empty directory that is removed when `body` returns.
public func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// A fresh, empty directory that is removed when `body` returns.
public nonisolated(nonsending) func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecorderKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
