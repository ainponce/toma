// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Library
import SwiftUI

/// One row of the list: a project, with the values its sortable columns compare.
struct LibraryRow: Identifiable {
    let item: LibraryItem

    var id: PackageIdentity { item.summary.identity }
    var name: String { item.summary.name }
    var recorded: Double { item.summary.recordedAt?.timeIntervalSince1970 ?? 0 }
    var duration: Double { item.summary.outputSeconds ?? 0 }
    var size: Int64 { item.summary.size ?? 0 }
}

/// The library as a list (design §6.2): the system's table with Name (and a thumbnail of 48 × 27), Date Recorded,
/// Duration, Format, Size, Location and Status. A click on the heading of Name, Date Recorded, Duration or Size sorts by
/// it (again, the other way); the rows come in the library's order. The table selects as the system's do (click, ⇧, ⌘,
/// ⌘A, the arrows); Esc selects nothing, and a double click or ↩ opens.
struct LibraryList: View {
    let model: LibraryModel

    var body: some View {
        let folderName = model.paths.projectsFolder.lastPathComponent
        Table(
            model.shown.map(LibraryRow.init), selection: Binding(get: { model.selection.selected }, set: { model.select($0) }),
            sortOrder: sortOrder
        ) {
            TableColumn(Text("Name", comment: "The library's list: a column"), value: \.name) { row in
                HStack(spacing: 8) {
                    ZStack {
                        PreviewArea.background
                        LibraryThumbnailView(model: model, item: row.item, isSmall: true)
                    }
                    .frame(width: LibraryLayout.listThumbnail.width, height: LibraryLayout.listThumbnail.height)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(verbatim: row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.item.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(Text("favorite", comment: "VoiceOver: a project of the library is a favorite"))
                    }
                }
                .opacity(LibraryTexts.isDimmed(row.item) ? 0.5 : 1)
                .help(Text(verbatim: LibraryTexts.help(row.item) ?? row.name))
                .onAppear { model.cardAppeared(row.id) }
                .onDisappear { model.cardDisappeared(row.id) }
            }
            .width(min: 180, ideal: 280)
            TableColumn(Text("Date Recorded", comment: "The library's list: a column, and an order"), value: \.recorded) { row in
                Text(verbatim: row.item.summary.recordedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
            .width(min: 120, ideal: 150)
            TableColumn(Text("Duration", comment: "The library's list: a column, and an order"), value: \.duration) { row in
                Text(verbatim: row.item.summary.outputSeconds.map(Timecode.duration) ?? "")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn(Text("Format", comment: "The library's list: a column")) { row in
                Text(verbatim: row.item.summary.aspect?.rawValue ?? "")
            }
            .width(min: 50, ideal: 60)
            TableColumn(Text("Size", comment: "The library's list: a column, and an order"), value: \.size) { row in
                Text(verbatim: row.item.summary.size.map { $0.formatted(.byteCount(style: .file)) } ?? "")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn(Text("Location", comment: "The library's list: a column")) { row in
                Text(verbatim: LibraryTexts.location(row.item, projectsFolderName: folderName))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 80, ideal: 140)
            TableColumn(Text("Status", comment: "The library's list: a column")) { row in
                Text(verbatim: LibraryTexts.status(row.item))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: PackageIdentity.self) { _ in
        } primaryAction: { ids in
            model.open(ids)
        }
        .onExitCommand { model.clearSelection() }
        .accessibilityLabel(Text("Projects", comment: "The library: what VoiceOver calls its grid and its list"))
    }

    /// The table's order is the library's: its first column's comparator says which and which way; Last Opened has no
    /// column, and shows none.
    private var sortOrder: Binding<[KeyPathComparator<LibraryRow>]> {
        Binding {
            let order: SortOrder = model.ascending ? .forward : .reverse
            switch model.sort {
            case .name: return [KeyPathComparator(\LibraryRow.name, order: order)]
            case .dateRecorded: return [KeyPathComparator(\LibraryRow.recorded, order: order)]
            case .duration: return [KeyPathComparator(\LibraryRow.duration, order: order)]
            case .size: return [KeyPathComparator(\LibraryRow.size, order: order)]
            case .lastOpened: return []
            }
        } set: { comparators in
            guard let first = comparators.first else { return }
            let sorts: [(PartialKeyPath<LibraryRow>, LibrarySort)] = [
                (\LibraryRow.name, .name), (\LibraryRow.recorded, .dateRecorded), (\LibraryRow.duration, .duration),
                (\LibraryRow.size, .size),
            ]
            guard let sort = sorts.first(where: { $0.0 == first.keyPath })?.1 else { return }
            model.sort = sort
            model.ascending = first.order == .forward
        }
    }
}
