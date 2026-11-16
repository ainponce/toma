// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// The stable id of a project: 32 lowercase hex digits that do not change when the package is renamed or moved.
///
/// A version 3 package keeps it in its manifest (`Manifest.projectID`): random when it is created at version 3, the
/// derived one when a version 1 or 2 package is upgraded with its first edit. A version 1 or 2 package has none, and
/// its id is the derived one, so its cache folder is the same before and after the upgrade.
public enum ProjectID {
    /// 16 random bytes as 32 lowercase hex digits.
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return hex((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The first 16 bytes, as 32 lowercase hex digits, of SHA-256 over the UTF-8 of `createdAt` as `ProjectJSON`
    /// writes it (ISO 8601) and `"\n"`, then for every take in order its `id`, `"\n"`, its `startedAt` in ISO 8601
    /// and `"\n"`. Nothing else of the manifest counts, so it is the same in every copy of a package.
    public static func derived(from manifest: Manifest) -> String {
        var text = iso8601(manifest.createdAt) + "\n"
        for take in manifest.takes {
            text += take.id + "\n" + iso8601(take.startedAt) + "\n"
        }
        return hex(SHA256.hash(data: Data(text.utf8)).prefix(16))
    }

    /// Whether `id` is exactly 32 lowercase hex digits.
    public static func isValid(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A date as `ProjectJSON.encoder()` writes it: ISO 8601 in UTC, without fractional seconds.
    private static func iso8601(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
