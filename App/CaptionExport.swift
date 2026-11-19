// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import ProjectFormat
import UniformTypeIdentifiers

/// The formats File ▸ Export Captions… writes (plan 2a decision 12).
enum CaptionFileFormat: String, CaseIterable {
    case srt, vtt

    var fileExtension: String { rawValue }

    var contentType: UTType {
        UTType(filenameExtension: rawValue) ?? .plainText
    }

    var title: String {
        switch self {
        case .srt: String(localized: "SubRip (.srt)", comment: "File ▸ Export Captions…: a format of the file")
        case .vtt: String(localized: "WebVTT (.vtt)", comment: "File ▸ Export Captions…: a format of the file")
        }
    }

    func text(of captions: [Caption]) -> String {
        switch self {
        case .srt: CaptionFiles.srt(captions)
        case .vtt: CaptionFiles.vtt(captions)
        }
    }
}

/// File ▸ Export Captions… (phase 2 design §5.2): the captions of the whole output, as the picture burns them at the
/// document's format (`CaptionLines`), to an `.srt` or `.vtt` file chosen in the save panel (with its Format, which it
/// remembers), written whole and atomically off the main thread.
extension EditorModel {
    private static let captionFormatKey = "captionExportFormat"

    /// Whether the document has a transcript to export captions of.
    var canExportCaptions: Bool {
        state == .ready && document?.transcript != nil
    }

    func exportCaptions() {
        guard canExportCaptions, let window, let document, let current = panelSession?.packageURL else { return }
        let remembered = UserDefaults.standard.string(forKey: Self.captionFormatKey).flatMap(CaptionFileFormat.init) ?? .srt
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = current.deletingLastPathComponent()
        let accessory = CaptionFormatAccessory(format: remembered, panel: panel, name: name)
        panel.accessoryView = accessory.view
        accessory.apply(remembered)
        // The captions as they are now, at the size the preview and the export burn them at.
        let size = StageLayout.outputSize(aspect: document.aspect, shortSide: 1080, contentRatio: contentRatio(of: document))
        let captions = CaptionLines.captions(of: document, timeMap: TimeMap(sequence: document.sequence), outputSize: size)
        Task {
            let response = await panel.beginSheetModal(for: window)
            let format = accessory.format
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(format.rawValue, forKey: Self.captionFormatKey)
            let data = Data(format.text(of: captions).utf8)
            do {
                try await Task.detached(priority: .userInitiated) { try DurableFile.writeAtomically(data, to: url) }.value
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(
                    localized: "Couldn't export the captions", comment: "An alert: File ▸ Export Captions… could not write the file")
                alert.informativeText = userFacingDescription(of: error)
                if let window = self.window, window.isVisible {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}

/// The save panel's "Format" menu: choosing one sets the file's type and extension.
@MainActor
private final class CaptionFormatAccessory: NSObject {
    let view: NSView
    private(set) var format: CaptionFileFormat
    private let popUp: NSPopUpButton
    private weak var panel: NSSavePanel?
    private let name: String

    init(format: CaptionFileFormat, panel: NSSavePanel, name: String) {
        self.format = format
        self.panel = panel
        self.name = name
        popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in CaptionFileFormat.allCases { popUp.addItem(withTitle: format.title) }
        popUp.selectItem(at: CaptionFileFormat.allCases.firstIndex(of: format) ?? 0)
        let label = NSTextField(labelWithString: String(localized: "Format"))
        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        view = stack
        super.init()
        popUp.target = self
        popUp.action = #selector(chosen(_:))
    }

    @objc private func chosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard CaptionFileFormat.allCases.indices.contains(index) else { return }
        apply(CaptionFileFormat.allCases[index])
    }

    /// The panel saves `format`, keeping the name typed with that extension.
    func apply(_ format: CaptionFileFormat) {
        self.format = format
        guard let panel else { return }
        panel.allowedContentTypes = [format.contentType]
        let typed = panel.nameFieldStringValue
        let base = typed.isEmpty ? name : (typed as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.fileExtension
    }
}
