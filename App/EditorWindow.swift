// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import SwiftUI

/// Allows one export at a time in the whole app: blocking reads of several exports at once starve each other.
@MainActor @Observable
final class ExportGate {
    var isBusy = false {
        didSet { if isBusy != oldValue { busyChanged() } }
    }
    /// Called when an export starts or ends; set by the app delegate.
    @ObservationIgnored var busyChanged: () -> Void = {}
}

/// The editor's window of one project (design §5.1): a unified toolbar with the bar (`EditorToolbar`) and, as content,
/// a vertical split whose top is a horizontal split of the preview (`PreviewArea`) and the panel's place (Task 37 adds
/// the system's inspector, `NSSplitViewItem(inspectorWithViewController:)`, `EditorPanel`), and whose bottom is the timeline's place
/// (Task 40, its divider between `EditorLayout.timelineHeightRange`). Each part is SwiftUI in an `NSHostingController`
/// whose view has the part's identifier (`preview`, `inspector`, `timeline`); the preview's bridges its `.toolbar` and
/// title to the window (`sceneBridgingOptions`), without which the bar would not appear.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let packageURL: URL
    private let model: EditorModel
    /// The panel's width and what it can be resized to.
    private static let panelWidth: CGFloat = 300
    private static let panelWidthRange: ClosedRange<CGFloat> = 260...380
    private let onClose: () -> Void
    /// Top to bottom: `horizontalSplit`, then the timeline.
    private let verticalSplit = NSSplitViewController()
    /// Left to right: the preview, then the panel.
    private let horizontalSplit = NSSplitViewController()
    /// Follows the window's toolbar, which SwiftUI gives it after it is made.
    private var toolbarObservation: NSKeyValueObservation?

    init(
        packageURL: URL, takeID: String?, exportGate: ExportGate, onRecovered: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.packageURL = packageURL
        self.onClose = onClose
        model = EditorModel(packageURL: packageURL, takeID: takeID, exportGate: exportGate)
        model.onRecovered = onRecovered
        let visible = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: EditorLayout.minimumSize)
        let size = EditorLayout.initialSize(visible: visible.size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = model.name
        window.representedURL = packageURL
        // The name is the bar's first item.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let preview = NSHostingController(rootView: EditorPreviewPane(model: model) { [weak self] in self?.togglePanel(nil) })
        preview.sceneBridgingOptions = [.toolbars, .title]
        // The window's size is its own (design §5.1), not what SwiftUI would like.
        preview.sizingOptions = []
        preview.view.identifier = NSUserInterfaceItemIdentifier("preview")
        horizontalSplit.splitView.isVertical = true
        horizontalSplit.addSplitViewItem(NSSplitViewItem(viewController: preview))
        // The panel is the system's inspector (decision 31): 300 pt, between 260 and 380.
        let panel = NSHostingController(rootView: EditorPanel(model: model))
        panel.sizingOptions = []
        panel.preferredContentSize = NSSize(width: Self.panelWidth, height: 0)
        panel.view.identifier = NSUserInterfaceItemIdentifier("inspector")
        let inspector = NSSplitViewItem(inspectorWithViewController: panel)
        inspector.minimumThickness = Self.panelWidthRange.lowerBound
        inspector.maximumThickness = Self.panelWidthRange.upperBound
        inspector.canCollapse = true
        inspector.isCollapsed = !model.panelVisible
        horizontalSplit.addSplitViewItem(inspector)
        verticalSplit.splitView.isVertical = false
        verticalSplit.addSplitViewItem(NSSplitViewItem(viewController: horizontalSplit))
        window.contentViewController = verticalSplit
        keepMinimumSize()
        toolbarObservation = window.observe(\.toolbar) { [weak self] _, _ in
            // Once the bar is laid out.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.keepMinimumSize() } }
        }
        window.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
            display: false)
        window.delegate = self
        model.window = window
        model.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Loads the project again if it could not be shown, for example after it was recovered.
    func reloadIfNeeded() {
        switch model.state {
        case .failed, .unfinished: model.load()
        case .opening, .recovering, .ready, .newerDocument: break
        }
    }

    /// Cancels an export in progress and returns once it has ended, its partial file removed.
    func cancelExportAndWait() async {
        await model.cancelExportAndWait()
    }

    // MARK: - The panel

    /// View ▸ Show Panel / Hide Panel (⌥⌘I) and the bar's `sidebar.right`: the inspector of the horizontal split, once
    /// there is one (Task 37), collapses or expands.
    @objc func togglePanel(_ sender: Any?) {
        model.panelVisible.toggle()
        if window?.isKeyWindow == true { KeyEditorPanel.shared.isVisible = model.panelVisible }
        guard let inspector = horizontalSplit.splitViewItems.first(where: { $0.behavior == .inspector }) else { return }
        inspector.animator().isCollapsed = !model.panelVisible
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        KeyEditorPanel.shared.isVisible = model.panelVisible
    }

    func windowDidResignKey(_ notification: Notification) {
        KeyEditorPanel.shared.isVisible = nil
    }

    /// The window's least size is `EditorLayout.minimumSize`, its bar included. AppKit keeps it as the content's least
    /// size, which the bar SwiftUI adds later would make taller: it is set from what the title bar and the bar take now.
    private func keepMinimumSize() {
        guard let window, let content = window.contentView else { return }
        let minimum = EditorLayout.minimumSize
        let decoration = window.frame.height - content.frame.height
        window.contentMinSize = NSSize(width: minimum.width, height: minimum.height - max(decoration, 0))
    }

    func windowWillClose(_ notification: Notification) {
        if window?.isKeyWindow == true { KeyEditorPanel.shared.isVisible = nil }
        model.close()
        // On the next turn: the window is still closing, and dropping this controller releases it.
        Task { self.onClose() }
    }

    #if DEBUG
    // MARK: - -TomaDumpEditorStructure

    /// The project opened, or could not be, and the bar has its items.
    var structureIsSettled: Bool {
        model.state != .opening && model.state != .recovering && !toolbarIdentifiers.isEmpty
    }

    /// The identifiers of the editor's items of the bar, from left to right as they are shown (AppKit lists the centered
    /// item first).
    var toolbarIdentifiers: [String] {
        let items = (window?.toolbar?.items ?? []).enumerated().filter { $0.element.itemIdentifier.rawValue.hasPrefix("editor.") }
        func x(_ item: NSToolbarItem) -> CGFloat? {
            guard let view = item.view, view.window != nil else { return nil }
            return view.convert(view.bounds, to: nil).minX
        }
        return items.sorted { a, b in
            guard let xa = x(a.element), let xb = x(b.element) else { return a.offset < b.offset }
            return xa < xb
        }.map(\.element.itemIdentifier.rawValue)
    }

    /// The identifiers of the splits' parts, in order, the splits inside a split in its place.
    var splitIdentifiers: [String] {
        func parts(of split: NSSplitViewController) -> [String] {
            split.splitViewItems.flatMap { item -> [String] in
                if let inner = item.viewController as? NSSplitViewController { return parts(of: inner) }
                return [item.viewController.view.identifier?.rawValue ?? "?"]
            }
        }
        return parts(of: verticalSplit)
    }
    #endif
}

/// The preview's part with the bar, which its hosting controller bridges to the window's toolbar.
private struct EditorPreviewPane: View {
    let model: EditorModel
    let togglePanel: () -> Void

    var body: some View {
        PreviewArea(model: model)
            .toolbar(id: "editor") {
                EditorToolbar(model: model, togglePanel: togglePanel)
            }
    }
}

/// The key editor's panel, for the View menu's item: SwiftUI's commands do not see an AppKit window's responder chain.
/// An `ObservableObject`, which commands follow (`@ObservedObject`).
@MainActor
final class KeyEditorPanel: ObservableObject {
    static let shared = KeyEditorPanel()
    /// Whether the key editor shows its panel; `nil` while no editor is the key window.
    @Published var isVisible: Bool?
}

/// View ▸ Show Panel / Hide Panel (⌥⌘I), in SwiftUI's View menu with the sidebar's commands (`InspectorCommands` is for
/// SwiftUI's scenes only), sent along the responder chain to the key editor.
struct EditorCommands: Commands {
    @ObservedObject var panel = KeyEditorPanel.shared

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            let isVisible = panel.isVisible
            Button(isVisible == false ? LocalizedStringKey("Show Panel") : LocalizedStringKey("Hide Panel")) {
                NSApp.sendAction(#selector(EditorWindowController.togglePanel(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(isVisible == nil)
        }
    }
}
