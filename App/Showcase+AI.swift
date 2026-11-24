// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Analysis
import AppSupport
import Foundation
import LocalAI
import ProjectFormat

/// The model of the screenshots (plan 5b decision 16; never in a library): it always writes, unless given a `reason`,
/// after `delay` seconds. Its chapters: one on the first line it is shown and one on each line that starts 60 s or
/// more after the last one, titled from a fixed list of Spanish titles of every length (so the sheet shows how long ones
/// fit); its title and summary are fixed, another title for an odd `variation`. Each line it is shown counts as one
/// token, so `linesPerPart` lines make a part.
struct ScriptedTextModel: TextModel {
    var reason: AIUnavailableReason?
    var delay: Double = 0
    /// The lines a part takes at most; `nil`: the whole transcript is one part.
    var linesPerPart: Int?

    static let titles = [
        "Introducción", "Instalar Toma desde la web", "Dar los permisos de grabación", "Elegir qué pantalla grabar",
        "La cámara y el micrófono", "Grabar la primera toma", "Cortar con la transcripción", "Zoom automático en los clics",
        "Subtítulos y su estilo", "Exportar para YouTube y redes sociales", "Preguntas frecuentes", "Cierre",
    ]

    static let summary = """
        Un recorrido por Toma, el grabador de pantalla para la Mac, desde la instalación hasta la primera grabación. \
        Muestra cómo elegir la pantalla, la cámara y el micrófono, y cómo editar el video cortando por su transcripción. \
        Termina con el zoom automático, los subtítulos y la exportación para YouTube.
        """

    func availability(language: String) -> AIAvailability {
        reason.map { .unavailable(reason: $0) } ?? .available
    }

    var contextSize: Int {
        linesPerPart.map { ChapterSuggester.reservedTokens + $0 } ?? 4096
    }

    func tokenCount(_ text: String) async -> Int {
        text.split(separator: "\n").count
    }

    func chapters(instructions: String, prompt: String) async throws -> [ProposedChapter] {
        try await wait()
        var chapters: [ProposedChapter] = []
        var last: Int?
        for line in prompt.split(separator: "\n") {
            guard let (index, seconds) = Self.start(of: line) else { continue }
            if let last, seconds < last + 60 { continue }
            last = seconds
            chapters.append(ProposedChapter(title: Self.titles[chapters.count % Self.titles.count], firstWordIndex: index))
        }
        return chapters
    }

    func text(_ kind: InfoKind, instructions: String, prompt: String, variation: Int) async throws -> String {
        try await wait()
        switch kind {
        case .title:
            return variation % 2 == 0 ? "Cómo instalar Toma y grabar la primera toma" : "Toma, de la instalación a la primera grabación"
        case .summary, .partSummary:
            return Self.summary
        }
    }

    private func wait() async throws {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    /// The number and the second of a line `[<number> @<m:ss>] <text>`.
    private static func start(of line: Substring) -> (Int, Int)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inside = line[line.index(after: line.startIndex)..<close].split(separator: " ")
        guard inside.count == 2, let index = Int(inside[0]), inside[1].hasPrefix("@") else { return nil }
        let clock = inside[1].dropFirst().split(separator: ":")
        guard clock.count == 2, let minutes = Int(clock[0]), let seconds = Int(clock[1]) else { return nil }
        return (index, minutes * 60 + seconds)
    }
}

extension EditorModel {
    /// `TOMA_SHOWCASE_AI=` (5b, `-TomaShowcase editor <package>`):
    /// - `info`: the Info tab with the title and the summary suggested;
    /// - `info-working`: the Info tab while the title is being written;
    /// - `sheet`: the chapters' sheet with what was proposed;
    /// - `sheet-working`: the sheet reading part 1 of 3, with a model that takes an hour;
    /// - `unavailable`: Apple Intelligence turned off, the Info tab and the sheet;
    /// - `no-transcript`: the Info tab and the sheet of a project without a transcript.
    /// - `add`: the chapters proposed and added, then undone, said in `<TOMA_SHOWCASE_AI_PNG>-add.txt`;
    /// - `esc`: Esc on the sheet that only has «OK», said in `<…PNG>-esc.txt`;
    /// - `draft-title`, `draft-summary`, `draft-tab`: text typed and left in its field, then the window closed or another
    ///   tab shown, said in `<…PNG>-draft.txt` (and on disk).
    /// `TOMA_SHOWCASE_AI_DELAY=<seconds>`: how long the scripted model takes to answer (0).
    func showcaseAI(_ environment: [String: String]) async {
        guard let variant = environment["TOMA_SHOWCASE_AI"] else { return }
        let delay = environment["TOMA_SHOWCASE_AI_DELAY"].flatMap(Double.init) ?? 0
        switch variant {
        case "info":
            showcase(ScriptedTextModel(delay: delay), tab: .info)
            ai.suggestTitle()
            await showcaseAIIdle()
            ai.suggestSummary()
            await showcaseAIIdle()
        case "info-working":
            showcase(ScriptedTextModel(delay: 3600), tab: .info)
            ai.suggestTitle()
        case "sheet":
            showcase(ScriptedTextModel(delay: delay), tab: nil)
            ai.proposeChapters()
        case "sheet-working":
            guard let document else { return }
            let words = TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence))
            let lines = TranscriptLines.make(words).count
            showcase(ScriptedTextModel(delay: 3600, linesPerPart: max((lines + 2) / 3, 1)), tab: nil)
            ai.proposeChapters()
        case "unavailable":
            showcase(ScriptedTextModel(reason: .appleIntelligenceNotEnabled), tab: .info)
            ai.proposeChapters()
        case "no-transcript":
            showcase(ScriptedTextModel(), tab: .info)
            ai.proposeChapters()
        case "add":
            // What «Add» does, in words, into `<TOMA_SHOWCASE_AI_PNG>-add.txt`: the named markers before, after «Add» with
            // every row and after one undo.
            showcase(ScriptedTextModel(), tab: nil)
            let before = visibleMarkers.filter { !$0.name.isEmpty }.count
            ai.proposeChapters()
            await showcaseAIIdle()
            guard case .proposed(let suggestions)? = ai.review else { return }
            ai.addChapters(suggestions.asChapters)
            try? await Task.sleep(for: .seconds(1))
            let added = visibleMarkers.filter { !$0.name.isEmpty }.map { "\(Timecode.duration(Double($0.output) / 1e9)) \($0.name)" }
            undo()
            try? await Task.sleep(for: .seconds(1))
            let undone = visibleMarkers.filter { !$0.name.isEmpty }.count
            let text = "before \(before)\nproposed \(suggestions.chapters.count)\nafter add \(added.count)\n"
                + added.joined(separator: "\n") + "\nafter one undo \(undone)\nsheet up \(window?.attachedSheet != nil)\n"
            if let path = environment["TOMA_SHOWCASE_AI_PNG"] { try? text.write(toFile: path + "-add.txt", atomically: true, encoding: .utf8) }
        case "esc":
            // Esc on the sheet that only has «OK» (Apple Intelligence off): whether it closed, into `<…PNG>-esc.txt`.
            showcase(ScriptedTextModel(reason: .appleIntelligenceNotEnabled), tab: nil)
            ai.proposeChapters()
            try? await Task.sleep(for: .seconds(1))
            let up = window?.attachedSheet != nil
            if let sheet = window?.attachedSheet, let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            {
                _ = sheet.performKeyEquivalent(with: escape)
            }
            try? await Task.sleep(for: .seconds(1))
            let text = "sheet up before esc \(up)\nsheet up after esc \(window?.attachedSheet != nil)\n"
            if let path = environment["TOMA_SHOWCASE_AI_PNG"] { try? text.write(toFile: path + "-esc.txt", atomically: true, encoding: .utf8) }
        case "draft-title", "draft-summary", "draft-tab":
            // Text typed into the title (or the summary) with the focus left in it, then the window closed (or, with
            // `draft-tab`, the Background tab shown): what the document has then, into `<…PNG>-draft.txt`.
            showcase(ScriptedTextModel(), tab: .info)
            try? await Task.sleep(for: .seconds(2))
            let typed = variant == "draft-summary" ? "Resumen escrito y no guardado." : "Título escrito y no guardado"
            guard let window, let content = window.contentView,
                let view = variant == "draft-summary" ? Self.summaryView(in: content) : Self.titleField(in: content)
            else { return }
            window.makeFirstResponder(view)
            try? await Task.sleep(for: .milliseconds(300))
            guard let editor = (view as? NSTextView) ?? (view as? NSTextField)?.currentEditor() as? NSTextView else { return }
            editor.selectAll(nil)
            editor.insertText(typed, replacementRange: editor.selectedRange())
            try? await Task.sleep(for: .milliseconds(500))
            var text = "focus kept \(window.firstResponder === editor)\n"
            if variant == "draft-tab" {
                panelTab = .background
                try? await Task.sleep(for: .seconds(1))
                text += "after tab: title \(document?.info?.title ?? "nil")\n"
            } else {
                window.close()
                text += "after close: closed \(closed)\n"
            }
            if let path = environment["TOMA_SHOWCASE_AI_PNG"] { try? text.write(toFile: path + "-draft.txt", atomically: true, encoding: .utf8) }
        default:
            break
        }
        // TOMA_SHOWCASE_AI_PNG=<path>: 3 s later, the sheet drawn into `<path>-sheet.png` (the window server can't
        // capture a window while the screen is locked; this draws the views themselves).
        guard let path = environment["TOMA_SHOWCASE_AI_PNG"] else { return }
        try? await Task.sleep(for: .seconds(3))
        if let sheet = window?.attachedSheet?.contentView { Self.showcasePNG(of: sheet, to: URL(filePath: path + "-sheet.png")) }
    }

    /// The Info tab's title field (by its placeholder).
    private static func titleField(in view: NSView) -> NSView? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == String(localized: "A title for the video") {
            return field
        }
        return view.subviews.lazy.compactMap { titleField(in: $0) }.first
    }

    /// The Info tab's summary (the panel's only editable text view that isn't a field's editor).
    private static func summaryView(in view: NSView) -> NSView? {
        if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor, view.enclosingScrollView?.superview != nil,
            text.string.hasPrefix("Un recorrido") || text.string.isEmpty
        {
            return text
        }
        return view.subviews.lazy.compactMap { summaryView(in: $0) }.first
    }

    /// `view` drawn into a PNG at `url`, over the window's background.
    private static func showcasePNG(of view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.displayIgnoringOpacity(view.bounds, in: context) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func showcase(_ textModel: ScriptedTextModel, tab: EditorPanelTab?) {
        ai.textModel = { textModel }
        ai.refreshAvailability()
        if let tab {
            panelVisible = true
            panelTab = tab
        }
    }

    private func showcaseAIIdle() async {
        while ai.work != .idle { try? await Task.sleep(for: .milliseconds(50)) }
    }
}
#endif
