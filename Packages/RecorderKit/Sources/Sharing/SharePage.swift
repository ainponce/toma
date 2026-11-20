// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CryptoKit
import Foundation

/// The page a share link opens, `index.html` (`sharePage-1`, fases 4 y 5 design §8.2, plan 5a decision 9): its own HTML
/// with its CSS inline, light and dark as the viewer's system is; the video with its poster; the title and the summary;
/// the chapters as links that work without a script (`<video>#t=N`) and one fixed script that jumps in the same player;
/// a Content Security Policy that allows only that script, that style and the objects' origin; `noindex`; and the Open
/// Graph tags of a chat's preview. Nothing from anyone else: no font, script, image or analytics but the link's own. The
/// only words are the caller's (`Labels`) and the project's. Its look is frozen: another look is another id.
public enum SharePage {
    public static let id = "sharePage-1"

    /// The page's own words, in the app's language (`toma`'s are in English).
    public struct Labels: Equatable, Sendable {
        /// The heading of the list of chapters.
        public var chapters: String
        /// The `lang` of the page, a BCP 47 tag.
        public var language: String

        public init(chapters: String, language: String) {
            self.chapters = chapters
            self.language = language
        }

        public static let english = Labels(chapters: "Chapters", language: "en")
    }

    /// What a page shows.
    public struct Content: Equatable, Sendable {
        public var title: String
        /// `nil` (or only spaces) has none.
        public var summary: String?
        /// The video's (`Chapters.list`), by start.
        public var chapters: [Chapter]
        /// Absolute: the public URL of `video.mp4`, or its signed one.
        public var videoURL: URL
        /// Absolute: the public URL of `poster.jpg`, or its signed one.
        public var posterURL: URL
        /// The page's own public URL (`og:url`); `nil` for a signed link, whose URL expires.
        public var pageURL: URL?
        /// The video's size in pixels, the poster's too.
        public var width: Int
        public var height: Int
        /// The video's, in ns of output: from an hour on, every chapter's clock has its hours.
        public var duration: Int64

        public init(
            title: String, summary: String?, chapters: [Chapter], videoURL: URL, posterURL: URL, pageURL: URL?, width: Int,
            height: Int, duration: Int64
        ) {
            self.title = title
            self.summary = summary
            self.chapters = chapters
            self.videoURL = videoURL
            self.posterURL = posterURL
            self.pageURL = pageURL
            self.width = width
            self.height = height
            self.duration = duration
        }
    }

    /// The page's only script, the content of its `<script>`, whose SHA-256 the CSP names: a click on a chapter (not one
    /// with a modifier, which opens the link as the browser does) plays the page's video from that chapter's second.
    public static let script = """

        document.addEventListener("click", function (event) {
          if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
          var link = event.target.closest ? event.target.closest("a[data-t]") : null;
          var video = document.querySelector("video");
          if (!link || !video) return;
          event.preventDefault();
          video.currentTime = Number(link.getAttribute("data-t"));
          var playing = video.play();
          if (playing && playing.catch) playing.catch(function () {});
          video.scrollIntoView({ block: "nearest" });
        });

        """

    /// The page's only style, the content of its `<style>`, whose SHA-256 the CSP names.
    static let style = """

        :root {
          color-scheme: light dark;
          --background: #f7f7f8;
          --text: #17171a;
          --secondary: #5f5f69;
          --separator: rgba(0, 0, 0, 0.1);
          --accent: #6b57f9;
          --hover: rgba(107, 87, 249, 0.1);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --background: #111113;
            --text: #f2f2f4;
            --secondary: #a3a3ad;
            --separator: rgba(255, 255, 255, 0.12);
            --accent: #8d77ff;
            --hover: rgba(141, 119, 255, 0.16);
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background: var(--background);
          color: var(--text);
          font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
          -webkit-text-size-adjust: 100%;
          text-size-adjust: 100%;
        }
        main { max-width: 960px; margin: 0 auto; padding: 24px 16px 48px; }
        video { display: block; width: 100%; height: auto; max-height: 80vh; border-radius: 12px; background: #000; }
        h1 { margin: 20px 0 0; font-size: 28px; line-height: 1.25; font-weight: 700; letter-spacing: -0.01em; overflow-wrap: anywhere; }
        .summary { margin: 8px 0 0; color: var(--secondary); white-space: pre-line; overflow-wrap: anywhere; }
        nav { margin-top: 28px; }
        h2 { margin: 0 0 8px; font-size: 13px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--secondary); }
        ol { list-style: none; margin: 0; padding: 0; border-top: 1px solid var(--separator); }
        li { border-bottom: 1px solid var(--separator); }
        a { display: flex; gap: 12px; padding: 10px 8px; color: inherit; text-decoration: none; border-radius: 8px; overflow-wrap: anywhere; }
        a:hover { background: var(--hover); }
        a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
        a span { flex: none; color: var(--accent); font-variant-numeric: tabular-nums; }
        @media (max-width: 600px) {
          main { padding-top: 16px; }
          video { border-radius: 8px; }
          h1 { font-size: 22px; }
        }

        """

    /// The page of `content` with `labels`, UTF-8 text for `index.html`.
    public static func html(_ content: Content, labels: Labels) -> String {
        let title = singleLine(content.title)
        let summary = content.summary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let video = content.videoURL.absoluteString, poster = content.posterURL.absoluteString
        let policy = [
            "default-src 'none'", "script-src \(hash(script))", "style-src \(hash(style))",
            "img-src \(origin(content.posterURL))", "media-src \(origin(content.videoURL))", "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")

        var head = [
            #"<meta charset="utf-8">"#,
            #"<meta name="viewport" content="width=device-width, initial-scale=1">"#,
            #"<meta http-equiv="Content-Security-Policy" content="\#(escaped(policy, apostrophes: false))">"#,
            #"<meta name="referrer" content="no-referrer">"#,
            #"<meta name="robots" content="noindex">"#,
            #"<meta name="color-scheme" content="light dark">"#,
            #"<meta name="generator" content="Toma \#(id)">"#,
            "<title>\(escaped(title))</title>",
            property("og:type", "video.other"),
            property("og:title", title),
        ]
        if let summary { head.append(property("og:description", singleLine(summary))) }
        head += [
            property("og:image", poster),
            property("og:image:type", "image/jpeg"),
            property("og:image:width", String(content.width)),
            property("og:image:height", String(content.height)),
            property("og:video", video),
            property("og:video:type", "video/mp4"),
            property("og:video:width", String(content.width)),
            property("og:video:height", String(content.height)),
        ]
        if let page = content.pageURL { head.append(property("og:url", page.absoluteString)) }
        head += [#"<meta name="twitter:card" content="summary_large_image">"#, "<style>\(style)</style>"]

        var main = [
            #"<video controls playsinline preload="metadata" poster="\#(escaped(poster))" width="\#(content.width)" height="\#(content.height)" src="\#(escaped(video))"></video>"#,
            "<h1>\(escaped(title))</h1>",
        ]
        if let summary { main.append(#"<p class="summary">\#(escaped(summary))</p>"#) }
        if !content.chapters.isEmpty {
            main += [#"<nav aria-labelledby="chapters">"#, #"<h2 id="chapters">\#(escaped(labels.chapters))</h2>"#, "<ol>"]
            for chapter in content.chapters {
                let t = max(chapter.start, 0) / 1_000_000_000
                let link = escaped("\(video)#t=\(t)")
                let clock = clock(chapter.start, duration: content.duration)
                let name = escaped(chapter.title.split(whereSeparator: \.isNewline).joined(separator: " "))
                main.append(#"<li><a href="\#(link)" data-t="\#(t)"><span>\#(clock)</span> \#(name)</a></li>"#)
            }
            main += ["</ol>", "</nav>"]
        }

        let lines = [
            "<!doctype html>", #"<html lang="\#(escaped(labels.language))">"#, "<head>",
        ] + head + ["</head>", "<body>", "<main>"] + main + ["</main>", "<script>\(script)</script>", "</body>", "</html>"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The clock of a chapter that starts at `start` ns in a video of `duration`: `MM:SS`, or `H:MM:SS` from an hour on,
    /// the same rule as each line of `Chapters.youTubeText`.
    public static func clock(_ start: Int64, duration: Int64) -> String {
        let total = max(start, 0) / 1_000_000_000
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        func two(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return duration / 1_000_000_000 >= 3600 ? "\(h):\(two(m)):\(two(s))" : "\(two(total / 60)):\(two(s))"
    }

    // MARK: - Private

    /// `text` for HTML, as text or inside a double-quoted attribute: `& < > " '` as `&amp; &lt; &gt; &quot; &#39;`;
    /// without `apostrophes`, `'` as it is, which a double-quoted attribute keeps (the CSP's `'none'`).
    static func escaped(_ text: String, apostrophes: Bool = true) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'" where apostrophes: result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// An Open Graph `<meta>`, `value` escaped.
    private static func property(_ name: String, _ value: String) -> String {
        #"<meta property="\#(name)" content="\#(escaped(value))">"#
    }

    /// `text` with each run of spaces and line breaks as one space, and none at its ends: a title or a description on
    /// one line, as a chat shows it.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The CSP source of `text`'s SHA-256: `'sha256-<base 64>'`.
    private static func hash(_ text: String) -> String {
        "'sha256-" + Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString() + "'"
    }

    /// `url`'s origin, as a CSP source: its scheme, host and port, if it has one (MinIO's `:9000`); nothing of its path or
    /// its query, so a signature is never in the policy.
    private static func origin(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return "'none'" }
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? "'none'"
    }
}
