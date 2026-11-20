// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A link shared from a project, a row of its `shares.json` (fases 4 y 5 design §8.3, plan 5a decision 4): the design's
/// six fields and where its objects are, so "Delete from Storage" removes that link's objects even after Settings ▸ Share
/// changed, and refuses when the storage is another one. It never holds the secret, nor a signature but the one of a
/// signed link's own `url`, which is what the person shares.
public struct ShareRecord: Codable, Equatable, Sendable, Identifiable {
    /// `ShareID`: 10 characters of base 32.
    public var id: String
    /// The link: `<public base>/<prefix><id>/index.html`, or `index.html`'s signed URL.
    public var url: String
    /// When it was shared, in whole seconds.
    public var createdAt: Date
    /// When a signed link stops working, in whole seconds; `nil` for a public link, which never does.
    public var expiresAt: Date?
    /// The bytes of its three objects together.
    public var bytes: Int64
    /// The SHA-256, in hex, of the document exported (`ShareInputs.documentHash`).
    public var documentHash: String
    /// The storage's endpoint, as Settings ▸ Share had it.
    public var endpoint: String
    public var bucket: String
    /// Where its objects are: `<prefix><id>/`.
    public var folder: String

    /// `createdAt` and `expiresAt` rounded down to whole seconds, as `shares.json` writes them.
    public init(
        id: String, url: String, createdAt: Date, expiresAt: Date?, bytes: Int64, documentHash: String,
        endpoint: String, bucket: String, folder: String
    ) {
        self.id = id
        self.url = url
        self.createdAt = createdAt.roundedToWholeSeconds
        self.expiresAt = expiresAt?.roundedToWholeSeconds
        self.bytes = bytes
        self.documentHash = documentHash
        self.endpoint = endpoint
        self.bucket = bucket
        self.folder = folder
    }

    /// Whether the link is public: it never expires.
    public var isPublic: Bool { expiresAt == nil }

    /// Whether a signed link no longer works at `now`; a public one never stops.
    public func hasExpired(at now: Date) -> Bool {
        expiresAt.map { now >= $0 } ?? false
    }

    /// The three objects of a link, in the order they are uploaded: the page last, so it never points at what is not
    /// there yet.
    public static let objectNames = ["video.mp4", "poster.jpg", "index.html"]

    /// The keys of its three objects in the bucket: `folder` and each of `objectNames`.
    public var objectKeys: [String] { Self.objectNames.map { folder + $0 } }

    private enum CodingKeys: String, CodingKey {
        case id, url, createdAt, expiresAt, bytes, documentHash, endpoint, bucket, folder
    }

    /// As it was written, if its `id` is a `ShareID` and its `folder` is a prefix and that id (`<prefix><id>/`, the prefix
    /// with no leading `/` nor an empty, `.` or `..` part): a row edited by hand never names other objects to delete.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        documentHash = try container.decode(String.self, forKey: .documentHash)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        bucket = try container.decode(String.self, forKey: .bucket)
        folder = try container.decode(String.self, forKey: .folder)
        guard ShareID.isValid(id), Self.isFolder(folder, of: id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .folder, in: container, debugDescription: "not a share's id and folder")
        }
    }

    /// Whether `folder` is `<prefix><id>/`, the prefix empty or parts that end in `/`, none empty, `.` or `..`.
    static func isFolder(_ folder: String, of id: String) -> Bool {
        guard folder.hasSuffix(id + "/") else { return false }
        let parts = folder.dropLast().split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
