// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CryptoKit
import Foundation
@testable import Sharing
import Testing

// The page `sharePage-1` (plan 5a decision 9): its own HTML, inline CSS and one fixed script whose hash the CSP allows,
// light and dark, Open Graph for a chat's preview, the chapters as links that jump, and nothing from anyone else.

private let second: Int64 = 1_000_000_000
private let folder = URL(string: "https://cdn.example.com/toma/k3m7q2x4za/")!
private let spanish = SharePage.Labels(chapters: "Capítulos", language: "es")

/// The page of the frozen test: a public link, two chapters, 3 minutes of 1920 × 1080.
private func demo(
    title: String = "Demo de Toma", summary: String? = "Dos frases. Otra.",
    chapters: [Chapter] = [Chapter(start: 0, title: "Intro"), Chapter(start: 65 * second, title: "Configuración ✨")],
    video: URL = folder.appending(path: "video.mp4"), poster: URL = folder.appending(path: "poster.jpg"),
    page: URL? = folder.appending(path: "index.html"), duration: Int64 = 180 * second
) -> SharePage.Content {
    SharePage.Content(
        title: title, summary: summary, chapters: chapters, videoURL: video, posterURL: poster, pageURL: page, width: 1920,
        height: 1080, duration: duration)
}

/// A video URL as S3 signs one, with its `&`s.
private let signedVideo = URL(string:
    "https://videos.s3.us-east-1.amazonaws.com/toma/k3m7q2x4za/video.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256"
    + "&X-Amz-Credential=AKIDEXAMPLE%2F20261120%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20261120T120000Z"
    + "&X-Amz-Expires=604800&X-Amz-SignedHeaders=host"
    + "&X-Amz-Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")!

/// The values of `attribute` of the elements `path` of `html`, read by an HTML parser (`XMLDocument`'s, which leaves out
/// the elements HTML 4 did not have: `<main>`, `<nav>`, `<video>`).
private func values(_ path: String, _ attribute: String, in html: String) throws -> [String] {
    let document = try XMLDocument(xmlString: html, options: [.documentTidyHTML])
    return try document.nodes(forXPath: "\(path)/@\(attribute)").compactMap(\.stringValue)
}

/// The value of `attribute` of the first `<tag>` of `html` as an HTML parser reads it: its text, as written, read in an
/// `<a href>`, an element the parser keeps (every attribute is read the same way).
private func attribute(_ attribute: String, ofTag tag: String, in html: String) throws -> String {
    let written = try #require(try Regex("<\(tag)\\b[^>]*\\s\(attribute)=\"([^\"]*)\"").firstMatch(in: html))
    let raw = try #require(written.output[1].substring)
    return try #require(try values("//a", "href", in: "<!doctype html><html><body><p><a href=\"\(raw)\">x</a></p></body></html>").first)
}

/// The `content` of the `<meta>` whose `property` (or `name`) is `key`; `nil` if there is none.
private func meta(_ key: String, in html: String) throws -> [String] {
    try values("//meta[@property='\(key)']", "content", in: html) + values("//meta[@name='\(key)']", "content", in: html)
}

/// What is between `<tag>` and `</tag>`, each time.
private func contents(of tag: String, in html: String) -> [String] {
    html.components(separatedBy: "<\(tag)>").dropFirst().compactMap { $0.components(separatedBy: "</\(tag)>").first }
}

@Suite struct SharePageTests {
    @Test func pageIsFrozen() {
        #expect(SharePage.id == "sharePage-1")
        let html = SharePage.html(demo(), labels: spanish)
        #expect(html == frozenPage, "the page of sharePage-1 changed: another look is another id")
    }

    @Test func textIsEscaped() throws {
        let title = #"<script>alert("x")</script> & 'y'"#
        let html = SharePage.html(
            demo(title: title, summary: "a < b > c", chapters: [Chapter(start: 0, title: #"<b>"one" & 'two'</b>"#)]),
            labels: spanish)
        let escaped = "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;y&#39;"
        #expect(html.contains("<title>\(escaped)</title>"))
        #expect(html.contains(#"<h1 dir="auto">\#(escaped)</h1>"#))
        #expect(html.contains(#"<meta property="og:title" content="\#(escaped)">"#))
        #expect(html.contains("a &lt; b &gt; c"))
        #expect(html.contains("&lt;b&gt;&quot;one&quot; &amp; &#39;two&#39;&lt;/b&gt;"))
        #expect(html.components(separatedBy: "<script").count == 2)
        #expect(try meta("og:title", in: html) == [title])
    }

    @Test func attributesEscapeAmpersands() throws {
        let poster = URL(string: signedVideo.absoluteString.replacingOccurrences(of: "video.mp4", with: "poster.jpg"))!
        let html = SharePage.html(demo(video: signedVideo, poster: poster, page: nil), labels: spanish)
        #expect(!html.contains("&X-Amz-"))
        #expect(html.contains("&amp;X-Amz-Credential="))
        #expect(try attribute("src", ofTag: "video", in: html) == signedVideo.absoluteString)
        #expect(try attribute("poster", ofTag: "video", in: html) == poster.absoluteString)
        #expect(try values("//a", "href", in: html) == [signedVideo.absoluteString + "#t=0", signedVideo.absoluteString + "#t=65"])
        #expect(try meta("og:video", in: html) == [signedVideo.absoluteString])
        #expect(try meta("og:image", in: html) == [poster.absoluteString])
        // The CSP names the objects' origin, never their query.
        let csp = try #require(try values("//meta[@http-equiv='Content-Security-Policy']", "content", in: html).first)
        #expect(csp.contains("img-src https://videos.s3.us-east-1.amazonaws.com;"))
        #expect(csp.contains("media-src https://videos.s3.us-east-1.amazonaws.com;"))
        #expect(!csp.contains("X-Amz"))
    }

    @Test func cspHashMatchesTheScript() throws {
        let html = SharePage.html(demo(), labels: spanish)
        let scripts = contents(of: "script", in: html)
        #expect(scripts == [SharePage.script])
        let styles = contents(of: "style", in: html)
        #expect(styles.count == 1)
        func hash(_ text: String) -> String { "'sha256-" + Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString() + "'" }
        let csp = try #require(try values("//meta[@http-equiv='Content-Security-Policy']", "content", in: html).first)
        let directives = Dictionary(uniqueKeysWithValues: csp.split(separator: ";").map { directive in
            let words = directive.split(separator: " ").map(String.init)
            return (words[0], Array(words.dropFirst()))
        })
        #expect(directives["default-src"] == ["'none'"])
        #expect(directives["script-src"] == [hash(SharePage.script)])
        #expect(directives["style-src"] == [hash(styles[0])])
        #expect(directives["img-src"] == ["https://cdn.example.com"])
        #expect(directives["media-src"] == ["https://cdn.example.com"])
        #expect(directives["base-uri"] == ["'none'"] && directives["form-action"] == ["'none'"])
        // The CSP comes before anything it governs.
        let cspAt = try #require(html.range(of: "Content-Security-Policy")).lowerBound
        #expect(cspAt < (try #require(html.range(of: "<style>")).lowerBound))
        // A port that is not the scheme's is part of the origin (MinIO).
        let local = URL(string: "http://localhost:9000/videos/toma/k3m7q2x4za/video.mp4?X-Amz-Expires=60&X-Amz-Signature=00")!
        let localHTML = SharePage.html(demo(video: local, poster: local, page: nil), labels: .english)
        #expect(localHTML.contains("media-src http://localhost:9000;"))
    }

    @Test func openGraphIsAbsoluteAndComplete() throws {
        let html = SharePage.html(demo(), labels: spanish)
        #expect(try meta("og:type", in: html) == ["video.other"])
        #expect(try meta("og:title", in: html) == ["Demo de Toma"])
        #expect(try meta("og:description", in: html) == ["Dos frases. Otra."])
        #expect(try meta("og:image", in: html) == [folder.appending(path: "poster.jpg").absoluteString])
        #expect(try meta("og:image:type", in: html) == ["image/jpeg"])
        #expect(try meta("og:image:width", in: html) == ["1920"] && meta("og:image:height", in: html) == ["1080"])
        #expect(try meta("og:video", in: html) == [folder.appending(path: "video.mp4").absoluteString])
        #expect(try meta("og:video:type", in: html) == ["video/mp4"])
        #expect(try meta("og:video:width", in: html) == ["1920"] && meta("og:video:height", in: html) == ["1080"])
        #expect(try meta("og:url", in: html) == [folder.appending(path: "index.html").absoluteString])
        #expect(try meta("twitter:card", in: html) == ["summary_large_image"])
        for key in ["og:image", "og:video", "og:url"] {
            #expect(try meta(key, in: html).allSatisfy { URL(string: $0)?.scheme == "https" })
        }
        // Without a summary there is no description; without a public link, no `og:url`. A summary's lines are one line.
        let signed = SharePage.html(demo(summary: nil, page: nil), labels: spanish)
        #expect(try meta("og:description", in: signed).isEmpty && meta("og:url", in: signed).isEmpty)
        #expect(!signed.contains(#"class="summary""#))
        let twoLines = SharePage.html(demo(summary: "Cómo grabar.\n\nEn dos   minutos."), labels: spanish)
        #expect(try meta("og:description", in: twoLines) == ["Cómo grabar. En dos minutos."])
        #expect(twoLines.contains("<p class=\"summary\" dir=\"auto\">Cómo grabar.\n\nEn dos   minutos.</p>"))
        // An empty summary is none.
        #expect(try meta("og:description", in: SharePage.html(demo(summary: "  \n"), labels: spanish)).isEmpty)
    }

    @Test func chaptersLinkToTheirSecond() throws {
        let video = folder.appending(path: "video.mp4").absoluteString
        let html = SharePage.html(demo(), labels: spanish)
        #expect(html.contains(#"<a href="\#(video)#t=65" data-t="65"><span>01:05</span> <span dir="auto">Configuración ✨</span></a>"#))
        #expect(html.contains(#"<a href="\#(video)#t=0" data-t="0"><span>00:00</span> <span dir="auto">Intro</span></a>"#))
        #expect(try values("//a", "data-t", in: html) == ["0", "65"])
        // From an hour on, every clock has its hours, as YouTube's text.
        let long: [Chapter] = [
            Chapter(start: 0, title: "Intro"), Chapter(start: 65 * second, title: "Uno"),
            Chapter(start: 3665 * second, title: "Dos\nlíneas"),
        ]
        let hour = SharePage.html(demo(chapters: long, duration: 62 * 60 * second), labels: spanish)
        #expect(hour.contains(#"data-t="3665"><span>1:01:05</span> <span dir="auto">Dos líneas</span></a>"#))
        #expect(hour.contains(#"data-t="65"><span>0:01:05</span> <span dir="auto">Uno</span></a>"#))
        for duration in [180 * second, 62 * 60 * second, 3600 * second - 1, 3600 * second] {
            let lines = Chapters.youTubeText(long, duration: duration).split(separator: "\n")
            for (chapter, line) in zip(long, lines) {
                #expect(line.hasPrefix(SharePage.clock(chapter.start, duration: duration) + " "))
            }
        }
    }

    @Test func noChaptersNoList() {
        let html = SharePage.html(demo(chapters: []), labels: spanish)
        #expect(!html.contains("Capítulos") && !html.contains("<nav") && !html.contains("<ol") && !html.contains("data-t=\""))
        // The script is there all the same: the page's CSP is one.
        #expect(contents(of: "script", in: html) == [SharePage.script])
        let english = SharePage.html(demo(), labels: .english)
        #expect(english.contains(#"<html lang="en">"#) && english.contains(">Chapters</h2>"))
        #expect(SharePage.Labels.english == SharePage.Labels(chapters: "Chapters", language: "en"))
    }

    @Test func rightToLeftTextIsShownInItsDirection() {
        let html = SharePage.html(
            demo(title: "שלום עולם", summary: "مرحبا بالعالم", chapters: [Chapter(start: 0, title: "פתיחה")]), labels: .english)
        #expect(html.contains(#"<h1 dir="auto">שלום עולם</h1>"#))
        #expect(html.contains(#"<p class="summary" dir="auto">مرحبا بالعالم</p>"#))
        #expect(html.contains(#"<span>00:00</span> <span dir="auto">פתיחה</span></a>"#))
        // The page keeps its language's direction: only the project's texts go their own way.
        #expect(html.contains(#"<html lang="en">"#) && !html.contains(#"dir="rtl""#))
    }

    @Test func bidiAndControlCharactersAreRemoved() throws {
        let controls = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        let html = SharePage.html(
            demo(
                title: "Demo\u{202E}lmth.exe\u{202C} \u{2066}x\u{2069}\u{0007}", summary: "Uno\u{202B} dos\u{0000}\ntres\u{7F}",
                chapters: [Chapter(start: 0, title: "Intro\u{2067}\u{001B}[31m")]),
            labels: spanish)
        for control in controls + ["\u{0000}", "\u{0007}", "\u{001B}", "\u{7F}"] {
            #expect(!html.unicodeScalars.contains(control.unicodeScalars.first!), "U+\(String(control.unicodeScalars.first!.value, radix: 16))")
        }
        #expect(html.contains(#"<h1 dir="auto">Demolmth.exe x</h1>"#))
        #expect(try meta("og:title", in: html) == ["Demolmth.exe x"])
        #expect(html.contains("<p class=\"summary\" dir=\"auto\">Uno dos\ntres</p>"))
        #expect(html.contains(#"<span dir="auto">Intro[31m</span>"#))
        // Marks that only say a direction stay: they turn nothing around.
        #expect(SharePage.html(demo(title: "a\u{200F}b"), labels: spanish).contains("<h1 dir=\"auto\">a\u{200F}b</h1>"))
    }

    @Test func openGraphTextIsCapped() throws {
        let family = "👩‍👩‍👧"
        // 68 letters and ten emoji of five scalars each: 78 characters.
        let title = String(repeating: "a", count: 68) + String(repeating: family, count: 10)
        let summary = String(repeating: "Una frase corta. ", count: 30) + "Fin."
        let html = SharePage.html(demo(title: title, summary: summary), labels: spanish)
        let ogTitle = try #require(try meta("og:title", in: html).first)
        #expect(ogTitle == String(repeating: "a", count: 68) + family + "…")
        #expect(ogTitle.count == SharePage.openGraphTitleLimit)
        let description = try #require(try meta("og:description", in: html).first)
        #expect(description.count <= SharePage.openGraphDescriptionLimit && description.hasSuffix("…"))
        #expect(description == String(summary.prefix(SharePage.openGraphDescriptionLimit - 1)).trimmingCharacters(in: .whitespaces) + "…")
        // The page has them whole, and the browser's tab the whole title.
        #expect(html.contains(#"<h1 dir="auto">\#(title)</h1>"#) && html.contains("<title>\(title)</title>"))
        #expect(html.contains(summary.trimmingCharacters(in: .whitespaces)))
        // At the limit, nothing is cut.
        let seventy = String(repeating: "b", count: 69) + family
        #expect(try meta("og:title", in: SharePage.html(demo(title: seventy), labels: spanish)) == [seventy])
        #expect(SharePage.capped("abc  def", to: 6) == "abc…")
    }

    @Test func nothingFromThirdParties() throws {
        let html = SharePage.html(demo(), labels: spanish)
        // The three objects, and their origin in the CSP.
        let given = Set(["video.mp4", "poster.jpg", "index.html"].map { folder.appending(path: $0).absoluteString })
            .union(["https://cdn.example.com"])
        let pattern = try Regex(#"https?://[^\s"'<>#);]+"#)
        let found = Set(html.matches(of: pattern).map { String(html[$0.range]) })
        #expect(found == given, "\(found.symmetricDifference(given))")
        // No address without its scheme (`//host/…`): every `//` is a `://`.
        #expect(html.components(separatedBy: "//").count == html.components(separatedBy: "://").count)
        #expect(!html.contains("@import") && !html.contains("url(") && !html.contains("<link") && !html.contains("<iframe"))
        #expect(try meta("robots", in: html) == ["noindex"])
        #expect(try meta("referrer", in: html) == ["no-referrer"])
        #expect(html.contains("color-scheme: light dark"))
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
        #expect(html.hasPrefix("<!doctype html>\n"))
    }
}

/// The page of `demo()` in Spanish, as the first implementation wrote it and a person read it. Changing it is another id.
private let frozenPage = """
    <!doctype html>
    <html lang="es">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-i8OL/HMOp5Q4LT3BbnHS/r2jQzJ8DM5DjcopRC9xfCw='; style-src 'sha256-pe/85XMnYstdz64evfBkvXy+AthI10DFg9S9enZSq4I='; img-src https://cdn.example.com; media-src https://cdn.example.com; base-uri 'none'; form-action 'none'">
    <meta name="referrer" content="no-referrer">
    <meta name="robots" content="noindex">
    <meta name="color-scheme" content="light dark">
    <meta name="generator" content="Toma sharePage-1">
    <title>Demo de Toma</title>
    <meta property="og:type" content="video.other">
    <meta property="og:title" content="Demo de Toma">
    <meta property="og:description" content="Dos frases. Otra.">
    <meta property="og:image" content="https://cdn.example.com/toma/k3m7q2x4za/poster.jpg">
    <meta property="og:image:type" content="image/jpeg">
    <meta property="og:image:width" content="1920">
    <meta property="og:image:height" content="1080">
    <meta property="og:video" content="https://cdn.example.com/toma/k3m7q2x4za/video.mp4">
    <meta property="og:video:type" content="video/mp4">
    <meta property="og:video:width" content="1920">
    <meta property="og:video:height" content="1080">
    <meta property="og:url" content="https://cdn.example.com/toma/k3m7q2x4za/index.html">
    <meta name="twitter:card" content="summary_large_image">
    <style>
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
    a span[dir] { flex: 1 1 auto; min-width: 0; color: inherit; font-variant-numeric: normal; }
    @media (max-width: 600px) {
      main { padding-top: 16px; }
      video { border-radius: 8px; }
      h1 { font-size: 22px; }
    }
    </style>
    </head>
    <body>
    <main>
    <video controls playsinline preload="metadata" poster="https://cdn.example.com/toma/k3m7q2x4za/poster.jpg" width="1920" height="1080" src="https://cdn.example.com/toma/k3m7q2x4za/video.mp4"></video>
    <h1 dir="auto">Demo de Toma</h1>
    <p class="summary" dir="auto">Dos frases. Otra.</p>
    <nav aria-labelledby="chapters">
    <h2 id="chapters">Capítulos</h2>
    <ol>
    <li><a href="https://cdn.example.com/toma/k3m7q2x4za/video.mp4#t=0" data-t="0"><span>00:00</span> <span dir="auto">Intro</span></a></li>
    <li><a href="https://cdn.example.com/toma/k3m7q2x4za/video.mp4#t=65" data-t="65"><span>01:05</span> <span dir="auto">Configuración ✨</span></a></li>
    </ol>
    </nav>
    </main>
    <script>
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
    </script>
    </body>
    </html>

    """
