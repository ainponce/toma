// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Library
import ProjectFormat
import SwiftUI

/// The library as a grid (design §6.2): columns of 200 to 260 pt, in sections by date when it is sorted by date (their
/// headings are headings for VoiceOver), each project a `LibraryCard`. Clicks, ⇧-clicks and ⌘-clicks select; the arrows
/// move the selection (with ⇧ they extend it), ⌘A selects everything, Esc nothing, a double click or ↩ opens, and "."
/// adds to the favorites or takes out of them (design §6.3). Cards an action moves settle with `Motion.trackItem`; one
/// that leaves shrinks to 90 % and fades (design §9).
struct LibraryGrid: View {
    let model: LibraryModel
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let padding = 20.0

    var body: some View {
        // The width in the same pass as the cards: they are laid out once, in their columns.
        GeometryReader { geometry in
            grid(width: geometry.size.width - 2 * Self.padding)
        }
    }

    private func grid(width: Double) -> some View {
        let columns = LibraryLayout.columns(width: width)
        let columnWidth = LibraryLayout.columnWidth(width: width, columns: columns)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(columnWidth), spacing: LibraryLayout.cardSpacing, alignment: .top),
                        count: columns),
                    alignment: .leading, spacing: LibraryLayout.cardSpacing
                ) {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.items, id: \.summary.identity) { item in
                                LibraryCard(
                                    model: model, item: item, isSelected: model.selection.selected.contains(item.summary.identity),
                                    showsTimeOnly: model.sort == .dateRecorded
                                ) { extending, toggling, isDouble in
                                    isFocused = true
                                    if isDouble {
                                        model.actions.cancelPendingRename()
                                        model.open([item.summary.identity])
                                    } else {
                                        model.click(item.summary.identity, extending: extending, toggling: toggling)
                                    }
                                }
                                .id(item.summary.identity)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                            }
                        } header: {
                            if let title = group.title {
                                Text(verbatim: title)
                                    .font(.title3.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                }
                .padding(Self.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Another order settles as an action does (design §9).
                .animation(.panel(Motion.trackItem, reduceMotion: reduceMotion), value: model.sort)
                .animation(.panel(Motion.trackItem, reduceMotion: reduceMotion), value: model.ascending)
            }
            // A click outside the cards selects nothing.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isFocused = true
                        model.clearSelection()
                    }
            }
            .onChange(of: columns, initial: true) { model.columns = columns }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
                handle(press, proxy: proxy)
            }
            .onKeyPress(".") {
                guard !LibraryActions.textFieldTakes(nil) else { return .ignored }
                model.perform(.toggleFavorite, on: model.selection.selected)
                return .handled
            }
            .onExitCommand { model.clearSelection() }
            .onCommand(#selector(NSText.selectAll(_:))) { model.selectAll() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Projects", comment: "The library: what VoiceOver calls its grid and its list"))
        }
    }

    /// The arrows, and ↩ (⌘O and ⌘↓ are the window's); none while a name is being edited, whose field takes them.
    private func handle(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !LibraryActions.textFieldTakes(nil) else { return .ignored }
        if press.key == .return {
            model.openSelection()
            return .handled
        }
        let move: LibraryMove
        switch press.key {
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .leftArrow: move = .left
        default: move = .right
        }
        guard let target = model.move(move, extending: press.modifiers.contains(.shift)) else { return .ignored }
        proxy.scrollTo(target)
        return .handled
    }
}

/// A project of the grid (design §6.2, §6.6): its thumbnail in a 16:9 frame with corners of 8 pt on the editor's gray
/// (#161618), a vertical or square one centred on it; the output's duration at the bottom right; the star at the top
/// left when it is a favorite or the pointer is over it; its state, if it has one; under it the name on one line (cut in
/// the middle) and "14:32 · 16:9". For VoiceOver it is one element with all of that in its label.
struct LibraryCard: View {
    let model: LibraryModel
    let item: LibraryItem
    let isSelected: Bool
    /// The grid is in sections by date: the card says only the time.
    let showsTimeOnly: Bool
    /// A click: with ⇧ (`extending`), with ⌘ (`toggling`), or the second of a double click.
    let onClick: (_ extending: Bool, _ toggling: Bool, _ isDouble: Bool) -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var id: PackageIdentity { item.summary.identity }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            frame
            VStack(alignment: .leading, spacing: 2) {
                if model.actions.renaming == id {
                    LibraryRenameField(model: model, item: item)
                } else {
                    Text(verbatim: item.summary.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .onTapGesture(perform: nameClicked)
                }
                Text(verbatim: LibraryTexts.subtitle(item, timeOnly: showsTimeOnly))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(isHovering ? 0.06 : 0))
        }
        .opacity(LibraryTexts.isDimmed(item) ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            onClick(flags.contains(.shift), flags.contains(.command), (NSApp.currentEvent?.clickCount ?? 1) >= 2)
        }
        .onHover { hovering in
            withAnimation(.panel(Motion.hover, reduceMotion: reduceMotion)) { isHovering = hovering }
        }
        .help(Text(verbatim: LibraryTexts.help(item) ?? item.summary.name))
        .contextMenu {
            // The selection, if the card is in it; otherwise the card alone.
            LibraryMenu(model: model, ids: model.selection.selected.contains(id) ? model.selection.selected : [id])
        }
        .onAppear { model.cardAppeared(id) }
        .onDisappear { model.cardDisappeared(id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: LibraryTexts.accessibilityLabel(item)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityActions {
            ForEach(LibraryActions.accessibilityCommands(for: item), id: \.self) { command in
                Button(LibraryActions.title(command, items: [item])) { model.perform(command, on: [id]) }
            }
        }
    }

    /// A click on the name: on the only card selected it edits the name, once it is not the first of a double click
    /// (which opens); otherwise a click on the card.
    private func nameClicked() {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let isDouble = (event?.clickCount ?? 1) >= 2
        if !isDouble, isSelected, model.selection.selected.count == 1, !flags.contains(.shift), !flags.contains(.command) {
            model.actions.renameAfterClick(id)
        } else {
            onClick(flags.contains(.shift), flags.contains(.command), isDouble)
        }
    }

    /// What a button over the thumbnail offers while the pointer is over the card: Restaurar in the trash, Recuperar for a
    /// take that did not finish saving (design §6.4, §6.6).
    private var hoverCommand: LibraryCommand? {
        if item.summary.place == .trash { return .restore }
        if item.summary.state == .unfinished, item.live != .recording { return .recover }
        return nil
    }

    /// The thumbnail's frame and what is drawn over it.
    private var frame: some View {
        ZStack {
            PreviewArea.background
            LibraryThumbnailView(model: model, item: item)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if let seconds = item.summary.outputSeconds, item.live != .recording {
                Text(verbatim: Timecode.duration(seconds))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.favorite || isHovering, item.summary.place != .trash {
                Button {
                    model.perform(.setFavorite(!item.favorite), on: [id])
                } label: {
                    Image(systemName: item.favorite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.favorite ? Color.yellow : Color.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.favorite ? LibraryActions.removeFromFavoritesTitle : LibraryActions.addToFavoritesTitle)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            LibraryStateBadge(item: item)
                .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if isHovering, model.actions.busy[id] == nil, let command = hoverCommand {
                Button(LibraryActions.title(command, items: [item])) { model.perform(command, on: [id]) }
                    .controlSize(.small)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let work = model.actions.busy[id] {
                ZStack {
                    Color.black.opacity(0.35)
                    if let progress = work.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                    } else {
                        ProgressView()
                    }
                }
                .controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
    }
}

/// A card's thumbnail, which arrives with a fade (`Motion.panelSwap`); until then, or when there is none, nothing over
/// the gray but a quiet symbol, and "Sin miniatura en esta ubicación" where none is drawn (design §6.5).
struct LibraryThumbnailView: View {
    let model: LibraryModel
    let item: LibraryItem
    /// The list's small one: no text.
    var isSmall = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let slot = model.thumbnail(for: item.summary.identity)
        ZStack {
            if item.live != .recording, let image = slot.image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Motion.panelSwapRise)))
                    .id(slot.version)
            } else if !isSmall, slot.isOffHere {
                Text("No thumbnail in this location", comment: "The library: a card in a synced or network location")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(8)
            } else if !isSmall {
                Image(systemName: "film")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: slot.version)
    }
}

/// The state of a project over its thumbnail (design §6.6): "● Grabando" with a dot that beats every 1.8 s (still with
/// Reduce motion), "Sin terminar", "No se puede abrir", "Necesita una versión más nueva de Toma", "Abierto en otra app",
/// "No disponible", a dot for one open in this app and a lock for one that cannot be written.
struct LibraryStateBadge: View {
    let item: LibraryItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if item.live == .recording {
            HStack(spacing: 4) {
                if reduceMotion {
                    dot
                } else {
                    PhaseAnimator([1.0, 0.25]) { opacity in
                        dot.opacity(opacity)
                    } animation: { _ in
                        // A beat every 1.8 s: 0.9 s down, 0.9 s up.
                        .easeInOut(duration: 0.9)
                    }
                }
                Text(LibraryTexts.recording)
            }
            .modifier(BadgeStyle())
        } else if let text = LibraryTexts.badge(item) {
            Text(verbatim: text)
                .modifier(BadgeStyle())
        } else if item.live == .openHere {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(4)
        } else if case .readOnlyVolume = item.summary.state {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .padding(4)
        }
    }

    private var dot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
    }

    private struct BadgeStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
        }
    }
}
