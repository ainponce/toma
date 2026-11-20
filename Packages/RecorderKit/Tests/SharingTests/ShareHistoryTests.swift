// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Sharing
import Testing

// `shares.json` (plan 5a decision 4): `{"version": 1, "shares": [...]}` at the root of the package, written whole and
// atomic under `flock` of the package's folder, read through no link; a file it cannot read is never written, and what it
// does not know survives.

/// A row of `shares.json` for `id`, shared `seconds` after a fixed instant.
private func record(_ id: String, at seconds: TimeInterval = 0, expires: Bool = true) -> ShareRecord {
    let created = Date(timeIntervalSince1970: 1_795_000_000 + seconds)
    return ShareRecord(
        id: id, url: "https://cdn.example.com/toma/\(id)/index.html", createdAt: created,
        expiresAt: expires ? created.addingTimeInterval(7 * 86_400) : nil, bytes: 1_234_567,
        documentHash: String(repeating: "ab", count: 32), endpoint: "https://example.r2.cloudflarestorage.com",
        bucket: "videos", folder: "toma/\(id)/")
}

/// A folder that stands for a package: `ShareHistory` reads and writes only its root.
private func makePackage(in dir: URL) throws -> ProjectPackage {
    let url = dir.appending(path: "Demo.toma", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return ProjectPackage(url: url)
}

private func sharesURL(_ package: ProjectPackage) -> URL {
    package.url.appending(path: ShareHistory.fileName)
}

/// The JSON object of `shares.json`.
private func object(_ package: ProjectPackage) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sharesURL(package))) as? [String: Any])
}

@Suite struct ShareHistoryTests {
    @Test func appendThenListNewestFirst() throws {
        try withTemporaryDirectory { dir in
            let history = ShareHistory(package: try makePackage(in: dir))
            try history.append(record("aaaaaaaaaa", at: 0))
            try history.append(record("bbbbbbbbbb", at: 60, expires: false))
            try history.append(record("cccccccccc", at: 30))
            #expect(try history.records().map(\.id) == ["bbbbbbbbbb", "cccccccccc", "aaaaaaaaaa"])
            #expect(try history.records().first == record("bbbbbbbbbb", at: 60, expires: false))
            // Two in the same second: the one appended last first.
            try history.append(record("dddddddddd", at: 60))
            #expect(try history.records().map(\.id).prefix(2) == ["dddddddddd", "bbbbbbbbbb"])
        }
    }

    @Test func missingFileIsEmpty() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            #expect(try ShareHistory(package: package).records().isEmpty)
            // Removing from no history writes none.
            try ShareHistory(package: package).remove(id: "aaaaaaaaaa")
            #expect(!FileManager.default.fileExists(atPath: sharesURL(package).path))
        }
    }

    @Test func writtenWithProjectJSON() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let shared = record("k3m7q2x4za", at: 0.75)
            try ShareHistory(package: package).append(shared)
            try ShareHistory(package: package).append(record("bbbbbbbbbb", at: 5, expires: false))
            let data = try Data(contentsOf: sharesURL(package))
            let rows: [ShareRecord] = [shared, record("bbbbbbbbbb", at: 5, expires: false)]
            struct File: Encodable { var version: Int; var shares: [ShareRecord] }
            #expect(data == (try ProjectJSON.encoder().encode(File(version: 1, shares: rows))))
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains(#""createdAt" : "2026-11-18T"#))
            // A public link has no `expiresAt`, never a `null`.
            #expect(!text.contains("null"))
            // Whole seconds: the row as listed is the one written.
            #expect(try ShareHistory(package: package).records().last == shared)
            #expect(shared.createdAt.timeIntervalSince1970 == 1_795_000_000)
            #expect(try object(package)["version"] as? Int == 1)
            // No temporary file is left behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: package.url.path) == [ShareHistory.fileName])
        }
    }

    @Test func unknownFieldsSurvive() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            var row = try #require(
                JSONSerialization.jsonObject(with: ProjectJSON.encoder().encode(record("aaaaaaaaaa"))) as? [String: Any])
            row["extra"] = 1
            let file: [String: Any] = ["version": 1, "shares": [row], "later": ["by": "a newer Toma"]]
            try JSONSerialization.data(withJSONObject: file).write(to: sharesURL(package))
            try ShareHistory(package: package).append(record("bbbbbbbbbb", at: 10))
            let read = try object(package)
            #expect((read["later"] as? [String: Any])?["by"] as? String == "a newer Toma")
            let shares = try #require(read["shares"] as? [[String: Any]])
            #expect(shares.count == 2)
            #expect(shares[0]["extra"] as? Int == 1 && shares[0]["id"] as? String == "aaaaaaaaaa")
            #expect(try ShareHistory(package: package).records().map(\.id) == ["bbbbbbbbbb", "aaaaaaaaaa"])
        }
    }

    @Test func recordsThatDoNotDecodeAreKeptNotListed() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            var good = try #require(
                JSONSerialization.jsonObject(with: ProjectJSON.encoder().encode(record("aaaaaaaaaa"))) as? [String: Any])
            var badFolder = good
            badFolder["id"] = "bbbbbbbbbb"
            badFolder["folder"] = "../bbbbbbbbbb/"
            var badID = good
            badID["id"] = "NOT-AN-ID!"
            badID["folder"] = "toma/NOT-AN-ID!/"
            good["url"] = "https://cdn.example.com/toma/aaaaaaaaaa/index.html"
            let shares: [Any] = ["a string", ["id": "cccccccccc"], badFolder, badID, good, 42]
            try JSONSerialization.data(withJSONObject: ["version": 1, "shares": shares]).write(to: sharesURL(package))
            #expect(try ShareHistory(package: package).records().map(\.id) == ["aaaaaaaaaa"])
            try ShareHistory(package: package).append(record("dddddddddd", at: 1))
            let kept = try #require(try object(package)["shares"] as? [Any])
            #expect(kept.count == 7)
            #expect(kept.first as? String == "a string" && kept[5] as? Int == 42)
            #expect(try ShareHistory(package: package).records().map(\.id) == ["dddddddddd", "aaaaaaaaaa"])
        }
    }

    @Test(arguments: ["not json", "oversized", "newer", "no shares", "an array", "empty"])
    func unreadableHistoryIsNeverOverwritten(_ kind: String) throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let bytes: Data
            switch kind {
            case "not json": bytes = Data("no es json".utf8)
            case "oversized":
                // Valid JSON, one byte more than the limit.
                let head = #"{"version":1,"shares":[],"pad":""#, tail = #""}"#
                bytes = Data((head + String(repeating: "x", count: ShareHistory.maxBytes + 1 - head.utf8.count - tail.utf8.count) + tail).utf8)
                #expect(bytes.count == ShareHistory.maxBytes + 1)
            case "newer": bytes = Data(#"{"version":2,"shares":[]}"#.utf8)
            case "no shares": bytes = Data(#"{"version":1}"#.utf8)
            case "an array": bytes = Data("[]".utf8)
            default: bytes = Data()
            }
            try bytes.write(to: sharesURL(package))
            let history = ShareHistory(package: package)
            #expect(throws: ShareError.historyUnreadable) { try history.records() }
            #expect(throws: ShareError.historyUnreadable) { try history.append(record("aaaaaaaaaa")) }
            #expect(throws: ShareError.historyUnreadable) { try history.remove(id: "aaaaaaaaaa") }
            #expect(try Data(contentsOf: sharesURL(package)) == bytes)
        }
    }

    @Test func aLimitSizedHistoryIsRead() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let head = #"{"version":1,"shares":[],"pad":""#, tail = #""}"#
            let bytes = Data((head + String(repeating: "x", count: ShareHistory.maxBytes - head.utf8.count - tail.utf8.count) + tail).utf8)
            try bytes.write(to: sharesURL(package))
            #expect(try ShareHistory(package: package).records().isEmpty)
            // One that would grow past the limit is not written: it would never be read again.
            #expect(throws: (any Error).self) { try ShareHistory(package: package).append(record("aaaaaaaaaa")) }
            #expect(try Data(contentsOf: sharesURL(package)) == bytes)
        }
    }

    @Test func aLinkedSharesFileIsNeverFollowed() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let outside = dir.appending(path: "outside.json")
            let original = try ProjectJSON.encoder().encode(["version": 1])
            try original.write(to: outside)
            try FileManager.default.createSymbolicLink(at: sharesURL(package), withDestinationURL: outside)
            let history = ShareHistory(package: package)
            #expect(throws: ShareError.historyUnreadable) { try history.records() }
            #expect(throws: ShareError.historyUnreadable) { try history.append(record("aaaaaaaaaa")) }
            #expect(try Data(contentsOf: outside) == original)
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: sharesURL(package).path)
            #expect(link == outside.path)
            // Nor is a folder in its place read or replaced.
            try FileManager.default.removeItem(at: sharesURL(package))
            try FileManager.default.createDirectory(at: sharesURL(package), withIntermediateDirectories: false)
            #expect(throws: ShareError.historyUnreadable) { try history.append(record("aaaaaaaaaa")) }
        }
    }

    @Test func concurrentAppendsKeepBoth() async throws {
        try await withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let histories = [ShareHistory(package: package), ShareHistory(package: ProjectPackage(url: package.url))]
            let ids = (0..<20).map { n in String(repeating: Array(ShareID.alphabet)[n], count: ShareID.length) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (n, id) in ids.enumerated() {
                    let history = histories[n % 2]
                    group.addTask { try history.append(record(id, at: TimeInterval(n))) }
                }
                try await group.waitForAll()
            }
            let listed = try histories[0].records()
            #expect(listed.count == 20)
            #expect(Set(listed.map(\.id)) == Set(ids))
        }
    }

    @Test func removeDropsOnlyThatID() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let history = ShareHistory(package: package)
            for (n, id) in ["aaaaaaaaaa", "bbbbbbbbbb", "cccccccccc"].enumerated() {
                try history.append(record(id, at: TimeInterval(n)))
            }
            try history.remove(id: "bbbbbbbbbb")
            #expect(try history.records().map(\.id) == ["cccccccccc", "aaaaaaaaaa"])
            // An id that is not there changes nothing.
            let before = try Data(contentsOf: sharesURL(package))
            try history.remove(id: "zzzzzzzzzz")
            #expect(try Data(contentsOf: sharesURL(package)) == before)
            try history.remove(id: "aaaaaaaaaa")
            try history.remove(id: "cccccccccc")
            #expect(try history.records().isEmpty)
            #expect(try (object(package)["shares"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func recordsKnowTheirObjectsAndExpiry() throws {
        let signed = record("k3m7q2x4za")
        #expect(signed.objectKeys == ["toma/k3m7q2x4za/video.mp4", "toma/k3m7q2x4za/poster.jpg", "toma/k3m7q2x4za/index.html"])
        #expect(!signed.isPublic)
        let expiry = try #require(signed.expiresAt)
        #expect(!signed.hasExpired(at: expiry.addingTimeInterval(-1)) && signed.hasExpired(at: expiry))
        let open = record("k3m7q2x4za", expires: false)
        #expect(open.isPublic && !open.hasExpired(at: .distantFuture))
    }
}
