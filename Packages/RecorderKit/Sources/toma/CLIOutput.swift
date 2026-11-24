// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat

/// What `toma` writes: the JSON of `--json` (`ProjectJSON`'s, keys sorted) and the texts for a person, one value a line,
/// times as `m:ss.mmm` of the output. The texts may change between versions; the JSON is the API.
enum CLIOutput {
    // MARK: - JSON

    static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? ProjectJSON.encoder().encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `{"error": {"code", "message"}}`.
    static func json(error: APIError) -> String {
        json(ErrorDocument(error: error))
    }

    private struct ErrorDocument: Encodable {
        var error: APIError
    }

    // MARK: - Texts

    /// `toma info`: the project's name, then a row for each part.
    static func info(_ report: ProjectReport) -> String {
        var rows: [(String, [String])] = [("path", [report.path])]
        rows.append(("format", ["\(report.formatVersion), " + (report.documentVersion.map { "document \($0)" } ?? "no edit document")]))
        if let info = report.info {
            if !info.title.isEmpty { rows.append(("title", [info.title])) }
            if !info.summary.isEmpty { rows.append(("summary", info.summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))) }
        }
        rows.append(("duration", ["\(time(report.duration)), \(report.frameRate) fps, \(report.aspect)"]))
        rows.append((
            "takes",
            report.takes.map { take in
                let tracks = take.tracks.map { "\($0.id) (\($0.kind))" }.joined(separator: ", ")
                let shown = take.inSequence ? "" : ", not in the sequence"
                return "\(take.id) \(take.status), \(time(take.seconds))\(shown): \(tracks)"
            }))
        rows.append(("sequence", [count(report.sequence.count, "clip")]))
        let named = report.markers.filter { !$0.name.isEmpty }.count
        rows.append(("markers", [count(report.markers.count, "marker") + (report.markers.isEmpty ? "" : ", \(named) named")]))
        rows.append(("chapters", report.chapters.isEmpty ? ["none"] : report.chapters.map { "\(time($0.start)) \($0.title)" }))
        let zoom = report.zoom
        var zoomText = zoom.enabled ? "automatic" : "not automatic"
        if zoom.enabled, zoom.followsFocus { zoomText += ", following the focus" }
        zoomText += ", depth \(number(zoom.depth))×, " + count(zoom.blocks.count, "block")
        rows.append(("zoom", [zoomText]))
        rows.append(("camera", [report.style.cameraLayout]))
        rows.append((
            "music",
            report.music.isEmpty
                ? ["none"] : report.music.map { "\($0.source) \(time($0.start))–\(time($0.end)), \(number($0.gain)) dB" }))
        rows.append(("transcript", [report.transcript.map { "\($0.language), \(count($0.words, "word"))" } ?? "none"]))
        if let warnings = report.warnings, !warnings.isEmpty { rows.append(("warnings", warnings)) }
        return report.name + "\n" + table(rows)
    }

    /// `toma markers`: a marker a line, its time, its id and its name.
    static func markers(_ report: MarkersReport) -> String {
        lines(report.markers.map { marker in
            [time(marker.at), marker.id, marker.name].filter { !$0.isEmpty }.joined(separator: "  ")
        })
    }

    /// `toma chapters`: a chapter a line, its start and its title; with `youTube`, as YouTube's description lists them.
    static func chapters(_ report: MarkersReport, youTube: Bool) -> String {
        youTube ? lines(report.youTube.isEmpty ? [] : [report.youTube])
            : lines(report.chapters.map { "\(time($0.start))  \($0.title)" })
    }

    /// `toma transcript`: the words the output says, in order.
    static func transcript(_ report: TranscriptReport) -> String {
        lines(report.text.isEmpty ? [] : [report.text])
    }

    /// `toma validate`: whether the package is valid, then what is wrong with it.
    static func validation(_ report: ValidationReport) -> String {
        var versions: [String] = []
        if let format = report.formatVersion { versions.append("format \(format)") }
        if let document = report.documentVersion { versions.append("document \(document)") }
        var out = [(report.valid ? "valid" : "not valid") + (versions.isEmpty ? "" : " (\(versions.joined(separator: ", ")))")]
        out += report.problems.map { "problem: \($0)" }
        out += report.missingFiles.map { "missing: \($0)" }
        if report.skippedEventLines > 0 {
            out.append("skipped: \(count(report.skippedEventLines, "line")) of the event logs that are not an event Toma reads")
        }
        return lines(out)
    }

    /// `toma edit`, `undo` and `redo`: what a command did, a line.
    static func command(_ result: CommandResult) -> String {
        let done = result.changed ? (result.label ?? "done") : "no change"
        let created = result.created.map { ", created \($0)" } ?? ""
        let warnings = (result.warnings ?? []).map { "  warning: \($0)\n" }.joined()
        return "\(result.command): \(done)\(created), output \(time(result.duration))\n" + warnings
    }

    /// `toma export`: where the file is and what it is.
    static func export(_ result: ExportResult) -> String {
        var parts = [result.codec ?? result.format, "\(result.width)×\(result.height)", "\(result.framesPerSecond) fps", time(result.duration)]
        if result.chapters > 0 { parts.append(count(result.chapters, "chapter")) }
        parts.append(String(format: "%.1f MB", Double(result.bytes) / 1_000_000))
        var out = ["\(result.path) (\(parts.joined(separator: ", ")))"]
        if let fcpxml = result.fcpxml { out.append(fcpxml) }
        if let metadata = result.metadata { out.append(metadata) }
        return lines(out)
    }

    // MARK: - Pieces

    /// `seconds` of output as `m:ss.mmm` (`h:mm:ss.mmm` from an hour).
    static func time(_ seconds: Double) -> String {
        let total = Int64((abs(seconds) * 1000).rounded())
        let sign = seconds < 0 && total > 0 ? "-" : ""
        let hours = total / 3_600_000, minutes = total / 60_000 % 60, secs = total / 1000 % 60, millis = total % 1000
        let tail = "\(pad(secs, 2)).\(pad(millis, 3))"
        return hours > 0 ? "\(sign)\(hours):\(pad(minutes, 2)):\(tail)" : "\(sign)\(minutes):\(tail)"
    }

    /// `value` with at most two decimals, without trailing zeros: `2`, `1.75`, `-14`.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 0 ? "no \(noun)s" : "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// Each line ended by a line break; nothing for none.
    private static func lines(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// Rows of a label and its values, the values one under the other, after labels of one width.
    private static func table(_ rows: [(String, [String])]) -> String {
        let width = (rows.map(\.0.count).max() ?? 0) + 2
        var out: [String] = []
        for (label, values) in rows {
            for (k, value) in values.enumerated() {
                let head = k == 0 ? label : ""
                out.append(head + String(repeating: " ", count: width - head.count) + value)
            }
        }
        return lines(out)
    }
}
