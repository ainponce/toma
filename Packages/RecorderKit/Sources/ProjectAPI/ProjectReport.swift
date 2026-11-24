// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// What `toma info` and `project_info` say of a project (fases 4 y 5 design §6.2): every time in seconds of the output,
/// as the project plays now, and the source's in nanoseconds of the take's clock (`sourceStart`, `t`). Its JSON is part
/// of the API: keys are only ever added.
public struct ProjectReport: Codable, Equatable, Sendable {
    /// The package's path.
    public var path: String
    /// The package's name, without `.toma`.
    public var name: String
    public var mode: TomaProject.Mode
    /// The manifest's `formatVersion`.
    public var formatVersion: Int
    /// The `documentVersion` the edit document is written in on disk; `nil` without one (a package of version 1 or 2,
    /// or one never edited).
    public var documentVersion: Int?
    public var info: ProjectInfo?
    public var duration: Double
    public var frameRate: Int
    /// `16:9`, `9:16`, `1:1`, `4:5`, `4:3`, `3:4` or `auto`.
    public var aspect: String
    public var takes: [TakeReport]
    public var sequence: [ClipReport]
    public var markers: [MarkerReport]
    public var chapters: [ChapterReport]
    public var zoom: ZoomReport
    public var style: StyleReport
    public var music: [MusicReport]
    public var transcript: TranscriptSummary?
    /// What the project is in that what is shown here does not say, in English, a sentence each: a take still being
    /// recorded, an edit document Toma sets aside or opens read-only. `nil` (left out of the JSON) with nothing to say.
    public var warnings: [String]?

    public init(
        path: String, name: String, mode: TomaProject.Mode, formatVersion: Int, documentVersion: Int?, info: ProjectInfo?,
        duration: Double, frameRate: Int, aspect: String, takes: [TakeReport], sequence: [ClipReport], markers: [MarkerReport],
        chapters: [ChapterReport], zoom: ZoomReport, style: StyleReport, music: [MusicReport], transcript: TranscriptSummary?,
        warnings: [String]? = nil
    ) {
        self.path = path
        self.name = name
        self.mode = mode
        self.formatVersion = formatVersion
        self.documentVersion = documentVersion
        self.info = info
        self.duration = duration
        self.frameRate = frameRate
        self.aspect = aspect
        self.takes = takes
        self.sequence = sequence
        self.markers = markers
        self.chapters = chapters
        self.zoom = zoom
        self.style = style
        self.music = music
        self.transcript = transcript
        self.warnings = warnings
    }
}

/// A take of the package.
public struct TakeReport: Codable, Equatable, Sendable {
    public var id: String
    /// `recording`, `complete` or `recovered`.
    public var status: String
    public var startedAt: Date
    /// How long what a document can show of it lasts (`TakeTimeline.editableBounds`), in seconds of the take.
    public var seconds: Double
    /// Whether the sequence shows it.
    public var inSequence: Bool
    public var tracks: [TrackReport]

    public init(id: String, status: String, startedAt: Date, seconds: Double, inSequence: Bool, tracks: [TrackReport]) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.seconds = seconds
        self.inSequence = inSequence
        self.tracks = tracks
    }
}

/// A track of a take.
public struct TrackReport: Codable, Equatable, Sendable {
    public var id: String
    /// `display`, `window`, `camera`, `microphone`…
    public var kind: String
    public var name: String

    public init(id: String, kind: String, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

/// A clip of the sequence, where the output plays it and what of its take it shows.
public struct ClipReport: Codable, Equatable, Sendable {
    public var id: String
    public var take: String
    public var start: Double
    public var end: Double
    /// Nanoseconds of the take's clock.
    public var sourceStart: UInt64
    public var sourceEnd: UInt64
    public var speed: Double
    /// `card`, `freeze` or `media` for a clip with content; `nil` for a stretch of its take.
    public var content: String?

    public init(
        id: String, take: String, start: Double, end: Double, sourceStart: UInt64, sourceEnd: UInt64, speed: Double, content: String?
    ) {
        self.id = id
        self.take = take
        self.start = start
        self.end = end
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
        self.content = content
    }
}

/// A marker the output shows (`MarkerList.visible`).
public struct MarkerReport: Codable, Equatable, Sendable {
    /// Its entry's id, or `rec-<take>-<ns>` for a recorded marker nobody has touched.
    public var id: String
    /// `""` has none.
    public var name: String
    /// Where the output shows it.
    public var at: Double
    public var take: String
    /// Its instant in nanoseconds of the take's clock.
    public var t: UInt64
    /// `recorded` or `added`.
    public var origin: String

    public init(id: String, name: String, at: Double, take: String, t: UInt64, origin: String) {
        self.id = id
        self.name = name
        self.at = at
        self.take = take
        self.t = t
        self.origin = origin
    }
}

/// A chapter (`Chapters.list`, `chapters-1`).
public struct ChapterReport: Codable, Equatable, Sendable {
    public var start: Double
    public var title: String

    public init(start: Double, title: String) {
        self.start = start
        self.title = title
    }
}

/// A piece of music.
public struct MusicReport: Codable, Equatable, Sendable {
    public var id: String
    /// `library:music-1/<theme>` or `assets/<name>`.
    public var source: String
    public var start: Double
    public var end: Double
    /// In dB.
    public var gain: Double

    public init(id: String, source: String, start: Double, end: Double, gain: Double) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.gain = gain
    }
}

/// The zoom: the automatic one's settings and the blocks the output shows.
public struct ZoomReport: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var followsFocus: Bool
    /// The project's depth, that of a block without one of its own.
    public var depth: Double
    public var blocks: [ZoomBlockReport]

    public init(enabled: Bool, followsFocus: Bool, depth: Double, blocks: [ZoomBlockReport]) {
        self.enabled = enabled
        self.followsFocus = followsFocus
        self.depth = depth
        self.blocks = blocks
    }
}

/// A zoom block the output shows.
public struct ZoomBlockReport: Codable, Equatable, Sendable {
    public var id: String
    /// `auto` or `user`.
    public var origin: String
    public var take: String
    public var start: Double
    public var end: Double
    public var sourceStart: UInt64
    public var sourceEnd: UInt64
    public var depth: Double?
    public var focus: CommandFocus
    /// `classic`, `calm` or `loupe` when the block has its own.
    public var mode: String?

    public init(
        id: String, origin: String, take: String, start: Double, end: Double, sourceStart: UInt64, sourceEnd: UInt64,
        depth: Double?, focus: CommandFocus, mode: String?
    ) {
        self.id = id
        self.origin = origin
        self.take = take
        self.start = start
        self.end = end
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.depth = depth
        self.focus = focus
        self.mode = mode
    }
}

/// The look: the document's `/style` as it is, and the camera's layout.
public struct StyleReport: Codable, Equatable, Sendable {
    public var style: JSONValue
    /// The project's camera layout: `bubble`, `screenOnly`, `split`, `cameraOnly` or `cameraFull`.
    public var cameraLayout: String

    public init(style: JSONValue, cameraLayout: String) {
        self.style = style
        self.cameraLayout = cameraLayout
    }
}

/// What the transcript has.
public struct TranscriptSummary: Codable, Equatable, Sendable {
    public var language: String
    public var words: Int
    public var takes: Int

    public init(language: String, words: Int, takes: Int) {
        self.language = language
        self.words = words
        self.takes = takes
    }
}

/// The transcript (`toma transcript`, `get_transcript`): the text the output says, and every word.
public struct TranscriptReport: Codable, Equatable, Sendable {
    public var language: String
    /// The words that are not cut, in output order, joined by spaces.
    public var text: String
    /// Every word of every take, in the transcript's order.
    public var words: [WordReport]
    /// What the output lasts, in seconds (so a reader can ask for parts of it, as `get_transcript` does); `nil` in a
    /// report made before it was added.
    public var duration: Double?

    public init(language: String, text: String, words: [WordReport], duration: Double? = nil) {
        self.language = language
        self.text = text
        self.words = words
        self.duration = duration
    }
}

/// A word of the transcript.
public struct WordReport: Codable, Equatable, Sendable {
    public var take: String
    public var text: String
    /// Where the output says it; `nil` for a word that is cut.
    public var start: Double?
    public var end: Double?
    public var sourceStart: UInt64
    public var sourceEnd: UInt64
    /// Whether the cuts leave it out (`TranscriptTiming.isCut`).
    public var cut: Bool

    public init(take: String, text: String, start: Double?, end: Double?, sourceStart: UInt64, sourceEnd: UInt64, cut: Bool) {
        self.take = take
        self.text = text
        self.start = start
        self.end = end
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.cut = cut
    }
}

/// The markers and the chapters (`toma markers`, `toma chapters`, `get_markers`).
public struct MarkersReport: Codable, Equatable, Sendable {
    public var markers: [MarkerReport]
    public var chapters: [ChapterReport]
    /// The chapters as YouTube's description lists them (`Chapters.youTubeText`): `00:00 Intro`, one a line.
    public var youTube: String

    public init(markers: [MarkerReport], chapters: [ChapterReport], youTube: String) {
        self.markers = markers
        self.chapters = chapters
        self.youTube = youTube
    }
}

// MARK: - Making them

/// How the reports are made from a document and its project.
enum Reports {
    static func seconds(_ nanoseconds: Int64) -> Double { Double(nanoseconds) / 1e9 }

    /// The title of the chapter at 00:00 when no named marker is in the first second (plan 4b decision 10):
    /// «Introducción» for a transcript in Spanish, «Intro» otherwise.
    static func introTitle(of document: EditDocument) -> String {
        let language = document.transcript?.language.lowercased() ?? ""
        return language == "es" || language.hasPrefix("es-") || language.hasPrefix("es_") ? "Introducción" : "Intro"
    }

    static func markers(_ visible: [VisibleMarker]) -> [MarkerReport] {
        visible.map { marker in
            MarkerReport(
                id: marker.id, name: marker.name, at: seconds(marker.output), take: marker.take, t: marker.t.nanoseconds,
                origin: marker.origin.rawValue)
        }
    }

    static func chapters(_ visible: [VisibleMarker], document: EditDocument) -> [Chapter] {
        Chapters.list(visible, duration: TimeMap(sequence: document.sequence).duration, introTitle: introTitle(of: document))
    }

    static func markersReport(_ visible: [VisibleMarker], document: EditDocument) -> MarkersReport {
        let chapters = chapters(visible, document: document)
        return MarkersReport(
            markers: markers(visible), chapters: chapters.map { ChapterReport(start: seconds($0.start), title: $0.title) },
            youTube: Chapters.youTubeText(chapters, duration: TimeMap(sequence: document.sequence).duration))
    }

    static func sequence(_ document: EditDocument, map: TimeMap) -> [ClipReport] {
        document.sequence.enumerated().map { k, clip in
            let start = map.clipOutputStarts[k]
            let end = k + 1 < document.sequence.count ? map.clipOutputStarts[k + 1] : map.duration
            let content: String? = switch clip.content {
            case nil: nil
            case .card?: "card"
            case .freeze?: "freeze"
            case .media?: "media"
            }
            return ClipReport(
                id: clip.id, take: clip.take, start: seconds(start), end: seconds(end), sourceStart: clip.start.nanoseconds,
                sourceEnd: clip.end.nanoseconds, speed: ClipSpeed.clamped(clip.speed), content: content)
        }
    }

    static func zoom(_ document: EditDocument, map: TimeMap) -> ZoomReport {
        let blocks = document.zoom.regions.compactMap { region -> ZoomBlockReport? in
            guard let output = map.outputRange(ofSource: region.start..<region.end, take: region.take) else { return nil }
            let focus: CommandFocus = switch region.focus {
            case .follow: .follow
            case let .fixed(x, y): .fixed(x: x, y: y)
            }
            return ZoomBlockReport(
                id: region.id, origin: region.origin.rawValue, take: region.take, start: seconds(output.lowerBound),
                end: seconds(output.upperBound), sourceStart: region.start.nanoseconds, sourceEnd: region.end.nanoseconds,
                depth: region.depth, focus: focus, mode: region.mode?.rawValue)
        }
        let auto = document.zoom.auto
        return ZoomReport(enabled: auto.enabled, followsFocus: auto.followsFocus, depth: auto.depth, blocks: blocks)
    }

    static func music(_ document: EditDocument) -> [MusicReport] {
        document.music.items.map { item in
            MusicReport(id: item.id, source: item.source, start: seconds(item.start), end: seconds(item.end), gain: item.gain)
        }
    }

    static func transcriptSummary(_ document: EditDocument) -> TranscriptSummary? {
        document.transcript.map { transcript in
            TranscriptSummary(
                language: transcript.language, words: transcript.takes.reduce(0) { $0 + $1.words.count }, takes: transcript.takes.count)
        }
    }

    static func transcript(_ document: EditDocument) -> TranscriptReport? {
        guard let transcript = document.transcript else { return nil }
        let map = TimeMap(sequence: document.sequence)
        let kept = TranscriptTiming.keptWords(of: document, timeMap: map)
        var outputs: [TranscriptWordRef: Range<Int64>] = [:]
        for word in kept { outputs[word.ref] = word.output }
        var words: [WordReport] = []
        for (t, take) in transcript.takes.enumerated() {
            let clips = document.sequence.filter { $0.take == take.take }
            for (w, word) in take.words.enumerated() {
                let output = outputs[TranscriptWordRef(take: t, word: w)]
                words.append(
                    WordReport(
                        take: take.take, text: word.text, start: output.map { seconds($0.lowerBound) },
                        end: output.map { seconds($0.upperBound) }, sourceStart: word.start.nanoseconds,
                        sourceEnd: word.end.nanoseconds, cut: TranscriptTiming.isCut(word, take: take.take, in: clips)))
            }
        }
        return TranscriptReport(
            language: transcript.language, text: kept.map(\.text).joined(separator: " "), words: words,
            duration: map.durationSeconds)
    }

    /// The takes of `project`'s manifest, each one's events read (from the disk, the first time): never on the main thread.
    static func takes(of project: LoadedProject, document: EditDocument) -> [TakeReport] {
        let shown = Set(document.sequence.map(\.take))
        return project.takes.map { take in
            let bounds = TakeTimeline.editableBounds(take: take, events: project.events(ofTake: take.id))
            let length = bounds.end > bounds.start ? bounds.end.nanoseconds - bounds.start.nanoseconds : 0
            return TakeReport(
                id: take.id, status: take.status.rawValue, startedAt: take.startedAt, seconds: Double(length) / 1e9,
                inSequence: shown.contains(take.id),
                tracks: take.tracks.map { TrackReport(id: $0.id, kind: $0.kind.rawValue, name: $0.source.name) })
        }
    }
}
