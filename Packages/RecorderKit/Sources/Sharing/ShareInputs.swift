// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CryptoKit
import Foundation
import ProjectFormat

/// What a project shares (fases 4 y 5 design §8.2, plan 5a decisions 9 to 11), read from its document as the editor
/// shows it: the page's title, summary and chapters, the frame of the poster, and the video's size, frame rate and the
/// hash of the document exported, which says whether an export already made can be reused.
public struct ShareInputs: Equatable, Sendable {
    /// The video's shorter side, in pixels: 1080p.
    public static let shortSide = 1080

    /// `info.title` without spaces at its ends, or the project's name.
    public var title: String
    /// `info.summary` without spaces at its ends; `nil` if it is empty.
    public var summary: String?
    /// The editor's chapters (`Chapters.list` of the markers the output shows).
    public var chapters: [Chapter]
    /// The poster's frame, ns of output on a frame of the video: the first marker the output shows, with or without a
    /// name, or 1 s, on the frame shown then; the last frame if the video is shorter.
    public var posterTime: Int64
    /// H.264 with the shorter side `shortSide` of the document's format.
    public var outputSize: SIMD2<Int>
    /// The document's frame rate, as the export sheet takes it (60 if it is not one of `EditDocument.frameRates`).
    public var framesPerSecond: Int
    /// `documentHash(_:)` of the document.
    public var documentHash: String

    public init(
        title: String, summary: String?, chapters: [Chapter], posterTime: Int64, outputSize: SIMD2<Int>,
        framesPerSecond: Int, documentHash: String
    ) {
        self.title = title
        self.summary = summary
        self.chapters = chapters
        self.posterTime = posterTime
        self.outputSize = outputSize
        self.framesPerSecond = framesPerSecond
        self.documentHash = documentHash
    }

    /// What `document` of `project` shares, with `recorded` the marker instants of the package's takes
    /// (`recordedMarkers(of:)`), `projectName` the title when the document has none, and `introTitle` the first chapter's
    /// when no named marker opens the video. Reads the events of the take `auto` follows (the disk, the first time): never
    /// on the main thread.
    /// - Throws: what encoding the document throws (`documentHash(_:)`).
    public static func make(
        project: LoadedProject, document: EditDocument, recorded: MarkerList.Recorded, projectName: String,
        introTitle: String
    ) throws -> ShareInputs {
        let timeMap = TimeMap(sequence: document.sequence)
        let markers = MarkerList.visible(document: document, recorded: recorded, timeMap: timeMap)
        let fps = EditDocument.frameRates.contains(document.frameRate) ? document.frameRate : 60
        let title = (document.info?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (document.info?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let last = timeMap.frameCount(frameRate: fps) - 1
        let frame = min(Self.frame(at: markers.first?.output ?? 1_000_000_000, frameRate: fps), last)
        return ShareInputs(
            title: title.isEmpty ? projectName : title,
            summary: summary.isEmpty ? nil : summary,
            chapters: Chapters.list(markers, duration: timeMap.duration, introTitle: introTitle),
            posterTime: TimeMap.frameTime(frame, frameRate: fps),
            outputSize: StageLayout.outputSize(
                aspect: document.aspect, shortSide: shortSide,
                contentRatio: StageLayout.contentRatio(project: project, document: document)),
            framesPerSecond: fps,
            documentHash: try documentHash(document))
    }

    /// The instants of the `marker` events of every take of `project`, by take id (`MarkerList.recordedInstants`), as the
    /// editor reads them when the project opens; a take without any has none. Reads each take's events (from the disk,
    /// the first time): never on the main thread.
    public static func recordedMarkers(of project: LoadedProject) -> MarkerList.Recorded {
        var recorded: MarkerList.Recorded = [:]
        for take in [project.take] + project.takes where recorded[take.id] == nil {
            let instants = MarkerList.recordedInstants(in: project.events(ofTake: take.id))
            if !instants.isEmpty { recorded[take.id] = instants }
        }
        return recorded
    }

    /// The SHA-256, in lowercase hex, of `document` as `ProjectJSON.encoder()` writes it: two documents that export the
    /// same video have the same one, and any edit changes it.
    public static func documentHash(_ document: EditDocument) throws -> String {
        SHA256.hash(data: try ProjectJSON.encoder().encode(document)).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    /// The frame of a video of `frameRate` shown at `τ` ns of output: the last `n` whose `TimeMap.frameTime(n,
    /// frameRate:)` is not after `τ`, `floor(τ · fps / 10⁹)` on the frame grid (0 before the start).
    static func frame(at τ: Int64, frameRate: Int) -> Int {
        guard τ > 0, frameRate > 0 else { return 0 }
        // The nearest estimate, then a frame either way where the grid's rounding puts its start a nanosecond off.
        var n = Int((Double(τ) / 1e9 * Double(frameRate)).rounded(.down))
        while n > 0, TimeMap.frameTime(n, frameRate: frameRate) > τ { n -= 1 }
        while TimeMap.frameTime(n + 1, frameRate: frameRate) <= τ { n += 1 }
        return n
    }
}
