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
/// the system's inspector, `NSSplitViewItem(inspectorWithViewController:)`), and whose bottom is the timeline's place
/// (Task 40, its divider between `EditorLayout.timelineHeightRange`). Each part is SwiftUI in an `NSHostingController`
/// whose view has the part's identifier (`preview`, `inspector`, `timeline`); the preview's bridges its `.toolbar` and
/// title to the window (`sceneBridgingOptions`), without which the bar would not appear.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let packageURL: URL
    private let model: EditorModel
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
        guard let inspector = horizontalSplit.splitViewItems.first(where: { $0.behavior == .inspector }) else { return }
        inspector.animator().isCollapsed = !model.panelVisible
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePanel(_:)) {
            menuItem.title = model.panelVisible ? String(localized: "Hide Panel") : String(localized: "Show Panel")
        }
        return true
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        EditorMenuItems.install()
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

/// The editor's items of the app's menus that SwiftUI's scenes cannot give an AppKit window: View ▸ Show Panel / Hide
/// Panel (⌥⌘I; `InspectorCommands` is for SwiftUI's scenes only), sent along the responder chain to the key editor.
@MainActor
enum EditorMenuItems {
    /// Adds them to the main menu if they are not there (SwiftUI may build the menu again): to the View menu, made before
    /// the Window menu if the app has none.
    static func install() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let toggle = #selector(EditorWindowController.togglePanel(_:))
        guard !mainMenu.items.contains(where: { $0.submenu?.items.contains { $0.action == toggle } == true }) else { return }
        let viewMenu = existingViewMenu(in: mainMenu) ?? makeViewMenu(in: mainMenu)
        if let last = viewMenu.items.last, !last.isSeparatorItem { viewMenu.addItem(.separator()) }
        let item = NSMenuItem(title: String(localized: "Show Panel"), action: toggle, keyEquivalent: "i")
        item.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(item)
    }

    /// The View menu SwiftUI makes, which has no items until it opens and no identifier: the one with the full screen or
    /// toolbar item, or else the one just before the Window menu, unless that is the Edit menu (it has Undo) or the
    /// app's.
    private static func existingViewMenu(in mainMenu: NSMenu) -> NSMenu? {
        let standard = [#selector(NSWindow.toggleFullScreen(_:)), #selector(NSWindow.toggleToolbarShown(_:))]
        if let menu = mainMenu.items.compactMap(\.submenu).first(where: { $0.items.contains { $0.action.map(standard.contains) == true } }) {
            return menu
        }
        guard let windows = NSApp.windowsMenu, let index = mainMenu.items.firstIndex(where: { $0.submenu === windows }),
            index > 1, let candidate = mainMenu.items[index - 1].submenu,
            !candidate.items.contains(where: { $0.action == Selector(("undo:")) })
        else { return nil }
        return candidate
    }

    private static func makeViewMenu(in mainMenu: NSMenu) -> NSMenu {
        let title = String(localized: "View")
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        let windowIndex = NSApp.windowsMenu.flatMap { windows in mainMenu.items.firstIndex { $0.submenu === windows } }
        mainMenu.insertItem(item, at: windowIndex ?? max(mainMenu.items.count - 1, 0))
        return menu
    }
}
