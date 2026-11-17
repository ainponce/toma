// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Library
import ProjectFormat
import SwiftUI
import UniformTypeIdentifiers

/// The library's one window (design §6.1): 1100 × 720 pt or 85 % of the visible area, whichever is smaller, at least
/// 760 × 480, where it was last if that is still on a screen. As the editor's, an AppKit frame around SwiftUI parts: a
/// split view whose sidebar item (the system's sidebar, its material, 200 pt) holds `LibrarySidebar` and whose other
/// item holds `LibraryContentView`, and the window's own toolbar: show or hide the sidebar, as Grid · as List (⌘1 · ⌘2),
/// Sort By and Search (⌘F). (Made in SwiftUI, with its split view and its toolbar, the first frame took about 70 ms
/// more, past design §15's 150 ms.)
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuDelegate
{
    let model: LibraryModel
    private let onClose: () -> Void
    private let split = NSSplitViewController()
    private var viewItem: NSToolbarItemGroup?
    private var sortItem: NSMenuToolbarItem?
    private var searchItem: NSSearchToolbarItem?
    /// The frame is saved once a move has settled.
    private var frameSave: Task<Void, Never>?
    /// Edit ▸ Undo and Redo of the library's actions.
    private lazy var libraryUndoManager = LibraryUndoManager(model: model)
    /// What is typed in a text field of the window, undone there; emptied when the editing ends, so nothing typed in one
    /// field is undone later in another.
    private let textUndoManager = UndoManager()
    private var editingEnded: (any NSObjectProtocol)?

    private static let viewIdentifier = NSToolbarItem.Identifier("library.view")
    private static let sortIdentifier = NSToolbarItem.Identifier("library.sort")
    private static let searchIdentifier = NSToolbarItem.Identifier("library.search")

    init(model: LibraryModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        // What it shows is read off the main thread while the window is made.
        model.start()
        // At its size before it has content: laid out once.
        let frame = Self.initialFrame(saved: model.frame)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.title = String(localized: "Library", comment: "The library's window and its title")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = LibraryLayout.minimumSize
        super.init(window: window)
        model.actions.window = window

        let toolbar = NSToolbar(identifier: "library")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self
        followTheModel()
        editingEnded = NotificationCenter.default.addObserver(
            forName: NSText.didEndEditingNotification, object: nil, queue: .main
        ) { [weak self] note in
            let text = note.object as? NSText
            MainActor.assumeIsolated {
                guard let self, text?.window === self.window else { return }
                self.textUndoManager.removeAllActions()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// How long a window being opened waits for the cached index before it shows without it.
    static let indexWait: Duration = .milliseconds(200)

    /// Calls `show` (which brings the window forward) once the cached index is shown, or after `indexWait` if it is
    /// slower: the window's first frame has the cards, and is laid out once. The main thread never waits.
    func showWhenLoaded(_ show: @escaping () -> Void) {
        Task {
            await model.whenLoaded(within: Self.indexWait)
            makeContent()
            show()
        }
    }

    /// Shown at once, without waiting for the index: the content is made now.
    override func showWindow(_ sender: Any?) {
        makeContent()
        super.showWindow(sender)
    }

    /// The split view and its SwiftUI parts, made once what they show is known: they are laid out once, with the cards.
    private func makeContent() {
        guard let window, split.splitViewItems.isEmpty else { return }
        let sidebar = NSHostingController(rootView: LibrarySidebar(model: model))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = LibraryLayout.sidebarWidth
        sidebarItem.maximumThickness = LibraryLayout.sidebarWidth
        sidebarItem.canCollapse = true
        let content = NSHostingController(
            rootView: LibraryContentView(model: model) { [weak self] in self?.searchItem?.beginSearchInteraction() })
        content.sizingOptions = []
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        // The window takes its content's size: the content takes the window's first.
        split.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = split
    }

    /// Where it was, if that is still on a screen and big enough; otherwise centred on the main screen.
    private static func initialFrame(saved: Rect?) -> NSRect {
        let screens = NSScreen.screens
        if let saved, let primary = screens.first {
            let frame = ScreenCoordinates.appKit(fromGlobal: saved, primaryScreenHeight: primary.frame.height)
            let isOnAScreen = screens.contains { screen in
                let overlap = screen.visibleFrame.intersection(frame)
                return overlap.width >= 100 && overlap.height >= 100
            }
            if isOnAScreen, frame.width >= LibraryLayout.minimumSize.width, frame.height >= LibraryLayout.minimumSize.height {
                return frame
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: LibraryLayout.minimumSize)
        let size = LibraryLayout.initialSize(visible: visible.size)
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - The toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.viewIdentifier, Self.sortIdentifier, Self.searchIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.viewIdentifier:
            let titles = [Self.gridTitle, Self.listTitle]
            let images = ["square.grid.2x2", "list.bullet"].enumerated().map { index, name in
                NSImage(systemSymbolName: name, accessibilityDescription: titles[index]) ?? NSImage()
            }
            let item = NSToolbarItemGroup(
                itemIdentifier: identifier, images: images, selectionMode: .selectOne, labels: titles, target: self,
                action: #selector(viewChosen(_:)))
            item.label = String(localized: "View", comment: "The library's bar: as a grid or as a list")
            for (index, subitem) in item.subitems.enumerated() { subitem.toolTip = titles[index] }
            item.selectedIndex = model.asList ? 1 : 0
            viewItem = item
            return item
        case Self.sortIdentifier:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            item.showsIndicator = true
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: Self.sortTitle)
            item.label = Self.sortTitle
            item.toolTip = Self.sortTitle
            sortItem = item
            updateSortItem()
            return item
        case Self.searchIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = String(localized: "Search", comment: "The library: the search field")
            item.searchField.delegate = self
            // Also when it is emptied with its button or Esc, which are not typing.
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.stringValue = model.search
            searchItem = item
            return item
        default:
            return nil
        }
    }

    @objc private func viewChosen(_ sender: NSToolbarItemGroup) {
        model.asList = sender.selectedIndex == 1
    }

    /// Sort By's menu, made when it opens: the orders, then Ascending · Descending, the chosen ones checked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: Self.sortTitle, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for sort in LibrarySort.allCases {
            let item = NSMenuItem(title: Self.title(sort), action: #selector(sortChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sort.rawValue
            item.state = model.sort == sort ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for ascending in [true, false] {
            let title =
                ascending
                ? String(localized: "Ascending", comment: "The library's bar: the order")
                : String(localized: "Descending", comment: "The library's bar: the order")
            let item = NSMenuItem(title: title, action: #selector(directionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ascending ? 1 : 0
            item.state = model.ascending == ascending ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func sortChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sort = LibrarySort(rawValue: raw) else { return }
        model.sort = sort
    }

    @objc private func directionChosen(_ sender: NSMenuItem) {
        model.ascending = sender.tag == 1
    }

    /// The search field's text is the library's search, as it is typed.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        model.search = field.stringValue
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        model.search = sender.stringValue
    }

    /// The bar follows what changes elsewhere (⌘1 and ⌘2, the list's headings).
    private func followTheModel() {
        withObservationTracking {
            _ = model.asList
            _ = model.sort
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.viewItem?.selectedIndex = self.model.asList ? 1 : 0
                    self.updateSortItem()
                    self.followTheModel()
                }
            }
        }
    }

    private func updateSortItem() {
        sortItem?.title = Self.title(model.sort)
    }

    private static var gridTitle: String { String(localized: "as Grid", comment: "The library's bar: the view") }
    private static var listTitle: String { String(localized: "as List", comment: "The library's bar: the view") }
    private static var sortTitle: String { String(localized: "Sort By", comment: "The library's bar: the order") }

    static func title(_ sort: LibrarySort) -> String {
        switch sort {
        case .dateRecorded: String(localized: "Date Recorded", comment: "The library's list: a column, and an order")
        case .name: String(localized: "Name", comment: "The library's list: a column")
        case .duration: String(localized: "Duration", comment: "The library's list: a column, and an order")
        case .size: String(localized: "Size", comment: "The library's list: a column, and an order")
        case .lastOpened: String(localized: "Last Opened", comment: "The library's bar: an order")
        }
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        model.windowBecameKey()
        KeyLibrary.shared.follow(model)
    }

    func windowDidResignKey(_ notification: Notification) {
        KeyLibrary.shared.stopFollowing(model)
    }

    /// Edit ▸ Undo and Redo (⌘Z, ⇧⌘Z): the library's history (`LibraryUndoManager`), unless a text field is being edited
    /// (a name, the search), whose typing they undo then.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndoManager : libraryUndoManager
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        frameSave?.cancel()
        frameSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveFrame()
        }
    }

    private func saveFrame() {
        guard let window, let primary = NSScreen.screens.first else { return }
        model.frame = ScreenCoordinates.global(fromAppKit: window.frame, primaryScreenHeight: primary.frame.height)
    }

    func windowWillClose(_ notification: Notification) {
        KeyLibrary.shared.stopFollowing(model)
        if let editingEnded { NotificationCenter.default.removeObserver(editingEnded) }
        editingEnded = nil
        frameSave?.cancel()
        saveFrame()
        Task {
            await model.close()
            // On a later turn: the window is still closing, and dropping this controller releases it.
            self.onClose()
        }
    }
}

/// Edit ▸ Undo and Redo (⌘Z, ⇧⌘Z) of the library's window (design §6.3): its history (`LibraryActionRunner`), whose steps
/// are undone and done again whole, as the window's own buttons did; the window validates the items with it and sends them
/// through it, so a key and the menu are the same one command. Nothing is registered in it.
final class LibraryUndoManager: UndoManager {
    private weak var model: LibraryModel?

    init(model: LibraryModel) {
        self.model = model
        super.init()
        disableUndoRegistration()
    }

    override var canUndo: Bool { model?.actions.canUndo == true && !LibraryWork.shared.isStopped }
    override var canRedo: Bool { model?.actions.canRedo == true && !LibraryWork.shared.isStopped }
    override var undoActionName: String { "" }
    override var redoActionName: String { "" }

    override func undo() {
        model?.perform(.undo)
    }

    override func redo() {
        model?.perform(.redo)
    }
}

/// The library's content beside the sidebar (design §6.1): a strip if there is one, what an action could not do, in the
/// trash its Vaciar la papelera…, then the grid or the list, or what an empty section says (design §10), with the trash
/// notice under them; ⌘1, ⌘2, ⌘F, ⌘O and ⌘↓, as the Finder has them, and the actions' ⌘D and ⌘⌫ (design §6.3); ⌘Z and
/// ⇧⌘Z are Edit ▸ Undo and Redo's (`LibraryUndoManager`). Packages dropped on it go to Other places, or are shown if they
/// are in the projects folder (design §6.2).
struct LibraryContentView: View {
    let model: LibraryModel
    /// ⌘F: the toolbar's search field takes the keys.
    let search: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            LibraryBannerView(model: model)
            LibraryFailureStrip(actions: model.actions)
            if model.section == .trash, (model.counts[.trash] ?? 0) > 0 {
                LibraryTrashBar(model: model)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            LibraryTrashNoticeView(actions: model.actions)
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: model.banner)
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: model.actions.failure)
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: model.actions.trashNotice)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            LibraryActions.loadDropped(providers) { urls in model.perform(.addProjects(urls)) }
            return true
        }
        .background { shortcuts }
    }

    @ViewBuilder private var content: some View {
        if !model.hasLoaded {
            Color.clear
        } else if model.shown.isEmpty {
            LibraryEmptyView(model: model)
        } else if model.asList {
            LibraryList(model: model)
        } else {
            LibraryGrid(model: model)
        }
    }

    /// Buttons nobody sees, for their shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button(String(localized: "as Grid", comment: "The library's bar: the view")) { model.asList = false }
                .keyboardShortcut("1", modifiers: .command)
            Button(String(localized: "as List", comment: "The library's bar: the view")) { model.asList = true }
                .keyboardShortcut("2", modifiers: .command)
            Button(String(localized: "Search", comment: "The library: the search field"), action: search)
                .keyboardShortcut("f", modifiers: .command)
            Button(String(localized: "Open", comment: "The library: opens the project")) { model.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.selection.selected.isEmpty)
            Button(String(localized: "Open", comment: "The library: opens the project")) { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.selection.selected.isEmpty)
            Button(LibraryActions.title(.duplicate, items: [])) {
                guard !LibraryActions.textFieldTakes(nil) else { return }
                model.perform(.duplicate, on: model.selection.selected)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model.selection.selected.isEmpty)
            Button(LibraryActions.title(.moveToTrash, items: [])) {
                guard !LibraryActions.textFieldTakes(#selector(NSResponder.deleteToBeginningOfLine(_:))) else { return }
                // In the trash it reaches nothing: a project is deleted only with Eliminar ahora…, after its alert.
                model.perform(.moveToTrash, on: model.selection.selected)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selection.selected.isEmpty)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// The strip above the content (design §10): the projects folder cannot be read (Show in Finder · Try Again), or the
/// project asked to open is being recorded.
private struct LibraryBannerView: View {
    let model: LibraryModel

    var body: some View {
        if let banner = model.banner {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: banner == .projectsFolderUnreadable ? "exclamationmark.triangle.fill" : "record.circle")
                        .foregroundStyle(banner == .projectsFolderUnreadable ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: Self.text(banner))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if banner == .projectsFolderUnreadable {
                        Button(String(localized: "Show in Finder")) { model.showProjectsFolderInFinder() }
                        Button(String(localized: "Try Again", comment: "The library: walk the projects folder again")) { model.retry() }
                    } else {
                        Button {
                            model.dismissNotice()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Close"))
                        .accessibilityLabel(Text("Close"))
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    banner == .projectsFolderUnreadable ? Color.orange.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                Divider()
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
        }
    }

    private static func text(_ banner: LibraryBanner) -> String {
        switch banner {
        case .projectsFolderUnreadable:
            String(localized: "The projects folder can't be read.", comment: "The library: a strip")
        case .recording:
            String(localized: "It's recording.", comment: "The library: a project being recorded does not open")
        }
    }
}

/// What an action could not do and why (design §6.3, §10), until it is closed or another failure takes its place.
private struct LibraryFailureStrip: View {
    let actions: LibraryActions

    var body: some View {
        if let failure = actions.failure {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    Text(verbatim: failure)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        actions.dismissFailure()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Close"))
                    .accessibilityLabel(Text("Close"))
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.18))
                Divider()
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The top of the trash (design §6.4): Vaciar la papelera…, which waits while projects are being deleted (the sidebar
/// says how far it went).
private struct LibraryTrashBar: View {
    let model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(LibraryActions.title(.emptyTrash, items: [])) { model.perform(.emptyTrash) }
                    .disabled(model.actions.emptying != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
        }
    }
}

/// "«Demo» se movió a la papelera. · Deshacer" under the content, for 8 s (design §6.3), with `Motion.panelSwap`.
private struct LibraryTrashNoticeView: View {
    let actions: LibraryActions

    var body: some View {
        if let notice = actions.trashNotice {
            HStack(spacing: 12) {
                Text(verbatim: notice)
                    .lineLimit(2)
                if actions.trashNoticeUndoes {
                    Button(LibraryActions.undoTitle) { actions.undoTrashNotice() }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
                Button {
                    actions.dismissTrashNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(Text("Close"))
                .accessibilityLabel(Text("Close"))
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.1)) }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 16)
            .transition(.opacity.combined(with: .offset(y: Motion.panelSwapRise)))
            .accessibilityElement(children: .contain)
        }
    }
}

/// What a section with nothing to show says (design §10).
private struct LibraryEmptyView: View {
    let model: LibraryModel

    var body: some View {
        VStack(spacing: 10) {
            if !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let search = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
                Text("Nothing matches “\(search)”.", comment: "The library: a search without results")
                    .font(.title3)
            } else {
                switch model.section {
                case .all:
                    if model.isLookingForProjects {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("No recordings yet.", comment: "The library without projects")
                            .font(.title3)
                        Text("Record from the notch or with \(model.host.recordShortcut()).", comment: "The library without projects: how to record")
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Record")) { model.host.record() }
                            .controlSize(.large)
                            .padding(.top, 4)
                    }
                case .favorites:
                    Text("Mark projects with ☆ to find them here.", comment: "The library: Favorites is empty")
                        .foregroundStyle(.secondary)
                case .otherPlaces:
                    Text("Projects opened from other folders show up here.", comment: "The library: Other Locations is empty")
                        .foregroundStyle(.secondary)
                case .trash:
                    Text("The trash is empty.", comment: "The library: the trash is empty")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
