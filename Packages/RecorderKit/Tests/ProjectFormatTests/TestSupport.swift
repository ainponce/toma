// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A fresh, empty directory that is removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectFormatTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}
