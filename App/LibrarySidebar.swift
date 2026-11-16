// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Library
import SwiftUI

/// The library's sidebar (design §6.1): All Projects, Favorites, Other Locations and Trash with how many each has; at its
/// foot, while projects are deleted for good "Vaciando… 3 de 12" (design §6.4), while the first walk finds projects
/// "Buscando proyectos… 340", a disk that is slow to answer, the free space of the projects folder's disk and, in the
/// trash, what it takes.
struct LibrarySidebar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: Binding<LibrarySection?>(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                Label {
                    Text(verbatim: Self.title(section))
                } icon: {
                    Image(systemName: Self.symbol(section))
                }
                .badge(model.counts[section] ?? 0)
                .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        let lines = footerLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
    }

    private var footerLines: [String] {
        var lines: [String] = []
        if let emptying = model.actions.emptying {
            lines.append(
                emptying.paused
                    ? String(localized: "Emptying… paused while recording", comment: "The library's sidebar: deleting for good waits for the take")
                    : String(
                        localized: "Emptying… \(emptying.done) of \(emptying.total)", comment: "The library's sidebar: deleting projects for good"))
        }
        if model.isLookingForProjects {
            lines.append(String(localized: "Looking for projects… \(model.projectsFound)", comment: "The library's sidebar: the first walk"))
        }
        for disk in model.waitingFor {
            lines.append(String(localized: "Waiting for disk “\(disk)”…", comment: "The library's sidebar: a disk slow to answer"))
        }
        if model.section == .trash, model.trashBytes > 0 {
            let size = model.trashBytes.formatted(.byteCount(style: .file))
            lines.append(String(localized: "\(size) in the trash", comment: "The library's sidebar: what the trash takes"))
        }
        if let free = model.freeSpace {
            let size = free.bytes.formatted(.byteCount(style: .file))
            lines.append(String(localized: "\(size) left on “\(free.volumeName)”", comment: "The library's sidebar: the free space of the projects folder's disk"))
        }
        return lines
    }

    static func title(_ section: LibrarySection) -> String {
        switch section {
        case .all: String(localized: "All Projects", comment: "The library's sidebar: a section")
        case .favorites: String(localized: "Favorites", comment: "The library's sidebar: a section")
        case .otherPlaces: String(localized: "Other Locations", comment: "The library's sidebar: a section")
        case .trash: String(localized: "Trash", comment: "The library: the section of the trash")
        }
    }

    private static func symbol(_ section: LibrarySection) -> String {
        switch section {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .otherPlaces: "folder"
        case .trash: "trash"
        }
    }
}
