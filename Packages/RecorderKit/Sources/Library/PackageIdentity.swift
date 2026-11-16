// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which project a package is, for the library (design §6.8): the UUID of its volume and the identifier of its folder
/// on that volume (`volumeUUIDStringKey` and `fileIdentifierKey`). It survives renaming the package and moving it within
/// its disk; a copy, a clone included, is another. Never the manifest's `projectID`, which a copy shares.
///
/// It is written as its `string`, `"<volume UUID>:<file identifier>"`, in the index and in `library.json` (design §13.4),
/// also as the key of an object (`lastOpened`, `trashOrigins`).
public struct PackageIdentity: Hashable, Codable, CodingKeyRepresentable, Sendable {
    public var volume: String
    public var file: UInt64

    public init(volume: String, file: UInt64) {
        self.volume = volume
        self.file = file
    }

    /// The identity of the package at `url` as `fileSystem` sees it: its volume's UUID and the identifier of the package
    /// folder itself (`lstat`: a link is its own item, never what it points to). Reads nothing inside the package.
    public init(of url: URL, in fileSystem: any LibraryFileSystem) throws {
        let volume = try fileSystem.volume(of: url).uuid
        self.init(volume: volume, file: try fileSystem.stat(url).fileID)
    }

    /// `"<volume>:<file>"`, the file identifier in decimal.
    public var string: String { "\(volume):\(file)" }

    /// The identity `string` writes, or `nil` if `string` is not exactly one: a volume that is not empty, a `:` and the
    /// file identifier in decimal digits with no sign, no leading zero and no spaces.
    public init?(string: String) {
        guard let colon = string.lastIndex(of: ":") else { return nil }
        let volume = String(string[..<colon])
        let digits = String(string[string.index(after: colon)...])
        guard !volume.isEmpty, let file = UInt64(digits), String(file) == digits else { return nil }
        self.init(volume: volume, file: file)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let identity = PackageIdentity(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a package identity: \(string)")
        }
        self = identity
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    public var codingKey: any CodingKey { Key(stringValue: string) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(string: codingKey.stringValue)
    }

    /// The key of an object that a `PackageIdentity` is: its `string`.
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
