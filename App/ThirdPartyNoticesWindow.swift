// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os

/// The licenses of the software the app includes or is built with, from `ThirdPartyNotices.txt`.
@MainActor
final class ThirdPartyNoticesWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Third-Party Licenses", comment: "The title of the window with the licenses of the software the app includes")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.string = Self.notices()
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        window.contentView = scrollView
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        // On the next turn: the window is still closing, and dropping this controller releases it.
        Task { self.onClose() }
    }

    private static func notices() -> String {
        do {
            guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("Cannot read ThirdPartyNotices.txt: \(String(describing: error), privacy: .public)")
            return String(localized: "The license notices are missing from this copy of the app.")
        }
    }
}
