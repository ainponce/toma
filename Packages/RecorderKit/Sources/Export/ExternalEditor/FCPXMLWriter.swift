// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The FCPXML 1.11 of an export (phases 4 and 5 design §7.2, plan 4c decision 9), written by hand (design §3: no
/// dependency): Final Cut Pro (and DaVinci Resolve, which reads it) opens a project with the exported video as one clip and,
/// on the clip, a chapter marker per marker the output shows, a marker a frame long per click and a range marker per zoom
/// block.
///
/// ```xml
/// <?xml version="1.0" encoding="UTF-8"?>
/// <!DOCTYPE fcpxml>
/// <fcpxml version="1.11">
///     <resources>
///         <format id="r1" frameDuration="1/30s" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
///         <asset id="r2" name="Demo" start="0s" duration="105/30s" hasVideo="1" format="r1" videoSources="1" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
///             <media-rep kind="original-media" src="file:///Users/me/Movies/Demo.mp4"/>
///         </asset>
///     </resources>
///     <library>
///         <event name="Project">
///             <project name="Demo">
///                 <sequence format="r1" duration="105/30s" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
///                     <spine>
///                         <asset-clip ref="r2" offset="0s" start="0s" duration="105/30s" name="Demo">
///                             <chapter-marker start="15/30s" duration="1/30s" value="Intro"/>
///                             <marker start="24/30s" duration="1/30s" value="Click"/>
///                             <marker start="36/30s" duration="21/30s" value="Zoom 2.0×"/>
///                         </asset-clip>
///                     </spine>
///                 </sequence>
///             </project>
///         </event>
///     </library>
/// </fcpxml>
/// ```
///
/// - Every time is a frame of the video: `"n/fps s"` (`"0s"` the 0), `n` its frame (`EditorTimeline`).
/// - The clip's markers go in order of start, a chapter marker before a click and a click before a zoom on the same frame.
///   A point lasts a frame; a zoom block lasts its frames in the video (`EditorTimeline.ZoomBlock.frames`).
/// - The labels are in the language of the chapters (`ExportSettings.chapterLanguage`, controller ruling over the plan):
///   Spanish for `es` ("Marcador" for a marker without a name, "Clic", "Zoom 2,0×", "Resaltar", "Atenuar", "Lupa"), English
///   otherwise ("Marker", "Click", "Zoom 2.0×", "Highlight", "Dim", "Loupe"), the depth with one decimal.
/// - The audio attributes of the asset are there only with an audio track; the sequence is mono with one channel, stereo
///   otherwise.
/// - Every text is escaped (`escaped(_:)`).
enum FCPXMLWriter {
    /// The FCPXML of `timeline`, the export of the video `video` describes, in an event named `event` (the project's) and a
    /// project named `project` (the video's), with the labels of `language` (a BCP 47 tag; English for `nil`).
    static func document(_ timeline: EditorTimeline, video: VideoFacts, event: String, project: String, language: String? = nil) -> Data {
        let fps = timeline.frameRate
        let labels = Labels(language: language)
        let duration = time(frame: timeline.frameCount, frameRate: fps)
        let name = escaped(project)

        var asset = """
            id="r2" name="\(name)" start="0s" duration="\(duration)" hasVideo="1" format="r1" videoSources="1"
            """
        if let channels = video.audioChannels {
            asset += #" hasAudio="1" audioSources="1" audioChannels="\#(channels)" audioRate="48000""#
        }
        let layout = video.audioChannels == 1 ? "mono" : "stereo"

        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            "<!DOCTYPE fcpxml>",
            #"<fcpxml version="\#(ExternalEditorExport.fcpxmlVersion)">"#,
            "    <resources>",
            #"        <format id="r1" frameDuration="\#(time(frame: 1, frameRate: fps))" width="\#(video.size.x)" height="\#(video.size.y)" colorSpace="1-1-1 (Rec. 709)"/>"#,
            "        <asset \(asset)>",
            #"            <media-rep kind="original-media" src="\#(escaped(video.url.absoluteString))"/>"#,
            "        </asset>",
            "    </resources>",
            "    <library>",
            #"        <event name="\#(escaped(event))">"#,
            #"            <project name="\#(name)">"#,
            #"                <sequence format="r1" duration="\#(duration)" tcStart="0s" tcFormat="NDF" audioLayout="\#(layout)" audioRate="48k">"#,
            "                    <spine>",
            #"                        <asset-clip ref="r2" offset="0s" start="0s" duration="\#(duration)" name="\#(name)">"#,
        ]
        for marker in markers(of: timeline, labels: labels) {
            lines.append(
                "                            <\(marker.element) start=\"\(time(frame: marker.frames.lowerBound, frameRate: fps))\" "
                    + "duration=\"\(time(frame: marker.frames.count, frameRate: fps))\" value=\"\(escaped(marker.value))\"/>")
        }
        lines += [
            "                        </asset-clip>",
            "                    </spine>",
            "                </sequence>",
            "            </project>",
            "        </event>",
            "    </library>",
            "</fcpxml>",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Frame `frame` at `frameRate` as an FCPXML time: `"0s"` for 0, `"<frame>/<frameRate>s"` otherwise.
    static func time(frame: Int, frameRate: Int) -> String {
        frame == 0 ? "0s" : "\(frame)/\(frameRate)s"
    }

    /// `text` for an attribute between double quotes: `&`, `<`, `>`, `"` and `'` as their entities, a tab and a line feed
    /// as character references (so a reader keeps them: an attribute's bare white space reads as a space), and the other
    /// C0 control characters, which XML 1.0 does not allow, and U+FFFE and U+FFFF left out.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t": result += "&#9;"
            case "\n": result += "&#10;"
            case "\u{0}"..."\u{1F}", "\u{FFFE}", "\u{FFFF}": continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// A marker of the clip.
    private struct ClipMarker {
        var element: String
        var frames: Range<Int>
        var value: String
        /// Which goes first on the same frame: the chapter markers, then the clicks, then the zoom blocks.
        var rank: Int
    }

    /// The clip's markers of `timeline`, in order of start (by rank on the same frame, then in their own order).
    private static func markers(of timeline: EditorTimeline, labels: Labels) -> [ClipMarker] {
        var all: [ClipMarker] = []
        all += timeline.markers.map { marker in
            ClipMarker(
                element: "chapter-marker", frames: marker.frame..<(marker.frame + 1),
                value: marker.name.isEmpty ? labels.marker : marker.name, rank: 0)
        }
        all += timeline.clicks.map { ClipMarker(element: "marker", frames: $0.frame..<($0.frame + 1), value: labels.click, rank: 1) }
        all += timeline.zoomBlocks.map { block in
            ClipMarker(element: "marker", frames: block.frames, value: labels.zoom(block.mode, depth: block.depth), rank: 2)
        }
        return all.enumerated()
            .sorted { a, b in
                (a.element.frames.lowerBound, a.element.rank, a.offset) < (b.element.frames.lowerBound, b.element.rank, b.offset)
            }
            .map(\.element)
    }

    /// The words of the markers in a language.
    struct Labels {
        let spanish: Bool

        /// Spanish for a tag whose language is `es`; English for any other and for `nil`.
        init(language: String?) {
            let code = language.flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
            spanish = code == "es"
        }

        /// A marker without a name.
        var marker: String { spanish ? "Marcador" : "Marker" }
        var click: String { spanish ? "Clic" : "Click" }

        /// A zoom block of `mode` and `depth`: its mode's name and the depth with one decimal, `"Zoom 2.0×"`.
        func zoom(_ mode: ZoomMode, depth: Double) -> String {
            let name = switch mode {
            case .classic: "Zoom"
            case .highlight: spanish ? "Resaltar" : "Highlight"
            case .dim: spanish ? "Atenuar" : "Dim"
            case .loupe: spanish ? "Lupa" : "Loupe"
            }
            let number = String(format: "%.1f", depth)
            return "\(name) \(spanish ? number.replacingOccurrences(of: ".", with: ",") : number)×"
        }
    }
}
