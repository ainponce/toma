// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// How the editor's window of a project was left (design §5.1), in `editor-state.json` of the project's cache folder:
/// state of the interface, never in the document, the log or the package, and made again from the defaults whenever it
/// is missing or damaged.
public struct EditorState: Codable, Equatable, Sendable {
    /// The panel's tab a project opens on the first time: Background.
    public static let defaultTab = "background"

    /// The window's frame, as AppKit gives it; `nil`, the initial size (design §5.1).
    public var windowFrame: Rect?
    /// The output frame the playhead is on.
    public var playheadFrame: Int
    /// Points per second of the timeline; `nil`, the whole sequence fitted to the window.
    public var timelineScale: Double?
    /// How far the timeline is scrolled, in points.
    public var timelineOffset: Double
    /// The panel's tab.
    public var tab: String
    public var panelVisible: Bool
    /// Whether the banner of a project of an earlier version (design §5.9) was closed.
    public var legacyBannerDismissed: Bool
    /// The layout of the last block made or changed in this project (1c plan decision 10): the next one takes it. `nil`
    /// until there is one, and in a file of 1b.
    public var lastBlockLayout: LayoutKind?

    public init(
        windowFrame: Rect? = nil, playheadFrame: Int = 0, timelineScale: Double? = nil, timelineOffset: Double = 0,
        tab: String = EditorState.defaultTab, panelVisible: Bool = true, legacyBannerDismissed: Bool = false,
        lastBlockLayout: LayoutKind? = nil
    ) {
        self.windowFrame = windowFrame
        self.playheadFrame = playheadFrame
        self.timelineScale = timelineScale
        self.timelineOffset = timelineOffset
        self.tab = tab
        self.panelVisible = panelVisible
        self.legacyBannerDismissed = legacyBannerDismissed
        self.lastBlockLayout = lastBlockLayout
    }

    /// The state in `editor-state.json` of `caches`, or `EditorState()` (the panel visible on Background, the timeline
    /// fitted to the window) if the file is missing, is not a regular file or is not a JSON object. A key that is missing,
    /// or whose value is not of its type or out of its range, keeps its default; a key this version does not know is
    /// ignored.
    public static func load(_ caches: ProjectCaches) -> EditorState {
        guard let data = ProjectCaches.read(caches.editorState),
              let state = try? ProjectJSON.decoder().decode(EditorState.self, from: data)
        else { return EditorState() }
        return state
    }

    /// Writes the state to `editor-state.json` of `caches` (making the folder if macOS emptied it) with the manifest's
    /// rules, replacing the file whole; never synced to the drive, so it can be called on the main thread. A write that
    /// fails is ignored: the next window opens with the defaults.
    public func save(_ caches: ProjectCaches) {
        guard let data = try? ProjectJSON.encoder().encode(self) else { return }
        ProjectCaches.write(data, to: caches.editorState)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let defaults = EditorState()
        self.init(
            windowFrame: value(.windowFrame, Rect.self).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil },
            playheadFrame: value(.playheadFrame, Int.self).flatMap { $0 >= 0 ? $0 : nil } ?? defaults.playheadFrame,
            timelineScale: value(.timelineScale, Double.self).flatMap { $0 > 0 ? $0 : nil },
            timelineOffset: value(.timelineOffset, Double.self).flatMap { $0 >= 0 ? $0 : nil } ?? defaults.timelineOffset,
            tab: value(.tab, String.self).flatMap { $0.isEmpty ? nil : $0 } ?? defaults.tab,
            panelVisible: value(.panelVisible, Bool.self) ?? defaults.panelVisible,
            legacyBannerDismissed: value(.legacyBannerDismissed, Bool.self) ?? defaults.legacyBannerDismissed,
            lastBlockLayout: value(.lastBlockLayout, LayoutKind.self))
    }
}
