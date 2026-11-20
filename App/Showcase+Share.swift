// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import AppSupport
import Foundation
import Sharing

extension EditorModel {
    /// `TOMA_SHOWCASE_SHARE=<variant>` (plan 5a, Task S4): Share's little window open over the editor, its state, settings
    /// and links made up (`EditorShare.showcase`); nothing is read from the Keychain or `shares.json`, nothing connects.
    /// - `unconfigured`: before Settings ▸ Share is set up.
    /// - `ready`: set up, with a signed link of 7 days; `ready-public`, with a public URL.
    /// - `running`: uploading, the bar's button a ring.
    /// - `finished`: the link shared and copied, and the links of before.
    /// - `failed`: the storage refused the keys.
    /// - `list`: set up, with the links of before (public, expiring, expired).
    func showcaseShare(_ environment: [String: String]) {
        guard let variant = environment["TOMA_SHOWCASE_SHARE"] else { return }
        let now = Date()
        var preferences = SharePreferences(
            provider: .r2, endpoint: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com", region: "auto",
            bucket: "toma-videos", prefix: "toma/", accessKeyID: "AKIAIOSFODNN7EXAMPLE")
        let earlier = [
            Self.showcaseRecord(id: "p7c2m4x6qa", created: now.addingTimeInterval(-2 * 86_400), expires: nil, bytes: 48_213_504),
            Self.showcaseRecord(
                id: "t2w5r7n3ab", created: now.addingTimeInterval(-4 * 86_400), expires: now.addingTimeInterval(3 * 86_400),
                bytes: 31_457_280),
            Self.showcaseRecord(
                id: "h4j6k2m5zq", created: now.addingTimeInterval(-16 * 86_400), expires: now.addingTimeInterval(-9 * 86_400),
                bytes: 12_582_912),
        ]
        switch variant {
        case "unconfigured":
            share.showcase(state: .idle, records: [], preferences: SharePreferences(), hasSecret: false)
        case "ready", "ready-public":
            if variant == "ready-public" { preferences.publicBaseURL = "https://videos.example.com" }
            share.showcase(state: .idle, records: [], preferences: preferences, hasSecret: true)
        case "running":
            share.showcase(
                state: .running(ShareProgress(phase: .uploading, fraction: 0.62)), records: earlier, preferences: preferences,
                hasSecret: true)
        case "finished":
            let shared = Self.showcaseRecord(
                id: "k3m7q2x4za", created: now, expires: now.addingTimeInterval(7 * 86_400), bytes: 52_428_800)
            share.showcase(
                state: .finished(shared), records: [shared] + earlier, preferences: preferences, hasSecret: true,
                copied: EditorShare.Copied(id: shared.id, note: ShareRules.note(for: shared, now: now)))
        case "failed":
            share.showcase(
                state: .failed(ShareTexts.describe(ShareError.authentication(code: "InvalidAccessKeyId"))), records: earlier,
                preferences: preferences, hasSecret: true)
        default:  // list
            share.showcase(state: .idle, records: earlier, preferences: preferences, hasSecret: true)
        }
        if let path = environment["TOMA_SHOWCASE_PANEL_PNG"] { Self.drawShareLater(window, to: path) }
    }

    /// `TOMA_SHOWCASE_PANEL_PNG=<path>` with `TOMA_SHOWCASE_SHARE`: three seconds later, the editor's window with its bar
    /// (not the preview's Metal layer) and Share's little window drawn into `<path>-window.png` and `<path>-share.png` by
    /// the views themselves, without the window server (which captures nothing while the screen is locked).
    private static func drawShareLater(_ window: NSWindow?, to path: String) {
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(3))
            let popover = NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible }
            for (view, name) in [(window?.contentView?.superview, "window"), (popover?.contentView?.superview, "share")] {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                    let context = NSGraphicsContext(bitmapImageRep: rep)
                else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    view.bounds.fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.displayIgnoringOpacity(view.bounds, in: context)
                }
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(name).png"))
            }
        }
    }

    /// A made-up link: public (`expires` nil) at a made-up domain, or signed as R2 signs it, with AWS's example key.
    private static func showcaseRecord(id: String, created: Date, expires: Date?, bytes: Int64) -> ShareRecord {
        let endpoint = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
        let url =
            expires == nil
            ? "https://videos.example.com/toma/\(id)/index.html"
            : "\(endpoint)/toma-videos/toma/\(id)/index.html?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20261120%2Fauto%2Fs3%2Faws4_request&X-Amz-Date=20261120T143000Z"
                + "&X-Amz-Expires=604800&X-Amz-SignedHeaders=host"
                + "&X-Amz-Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
        return ShareRecord(
            id: id, url: url, createdAt: created, expiresAt: expires, bytes: bytes, documentHash: "", endpoint: endpoint,
            bucket: "toma-videos", folder: "toma/\(id)/")
    }
}
#endif
