// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Where the local AI (`EditorAI`) shows itself in the editor's window: the chapters' review sheet.
extension EditorModel {
    /// The chapters' review sheet (`ChapterReviewSheet`, 520 × 460) over the window, showing `ai.review`; `nil` if the
    /// window has another sheet up. `ai` ends it.
    func beginChapterReview(_ ai: EditorAI) -> NSWindow? {
        guard let window, window.attachedSheet == nil else { return nil }
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ChapterReviewSheet.size.width, height: ChapterReviewSheet.size.height),
            styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = NSHostingController(rootView: ChapterReviewSheet(model: self, ai: ai))
        window.beginSheet(sheet)
        return sheet
    }
}
