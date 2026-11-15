// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import SwiftUI

// The open island's columns and rows, shared by what each mode shows in them.

/// A column of the open island: a card with its content from the top.
struct Column<Content: View>: View {
    let width: Double
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.10)))
            }
    }
}

struct ColumnTitle: View {
    let text: Text
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
            text.textCase(.uppercase).tracking(0.9)
        }
        .font(.system(size: 11, weight: .semibold))
        .opacity(0.62)
    }
}

struct ColumnSubtitle: View {
    let text: Text
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
            text
        }
        .font(.system(size: 11))
        .opacity(0.62)
    }
}

/// A short note at the bottom of a column.
struct ColumnNote: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 11))
            .opacity(0.62)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row that can be chosen (a display, a window, an area): its title and a smaller line under it, an icon
/// before them if it has one, and a check that grows in once it is chosen (with "Reduce motion", fades in).
struct ChoiceRow: View {
    let title: Text
    var subtitle: Text?
    /// An app's icon, or a symbol.
    var icon: RowIcon?
    let isChosen: Bool
    let choose: () -> Void
    /// The pointer entered (`true`) or left the row.
    var hovering: ((Bool) -> Void)?
    @State private var isHovered = false
    @Environment(\.islandReduceMotion) private var reduceMotion

    enum RowIcon {
        case symbol(String)
        case image(NSImage)
    }

    var body: some View {
        HStack(spacing: 8) {
            switch icon {
            case .symbol(let name):
                Image(systemName: name).symbolRenderingMode(.hierarchical).font(.system(size: 12)).opacity(0.75)
            case .image(let image):
                Image(nsImage: image).resizable().frame(width: 18, height: 18)
            case nil:
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 1) {
                title.font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if let subtitle { subtitle.font(.system(size: 11)).opacity(0.6).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(nsColor: .systemBlue)))
                // It grows in; with "Reduce motion" it fades in.
                .scaleEffect(reduceMotion || isChosen ? 1 : 0.001)
                .opacity(reduceMotion && !isChosen ? 0 : 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isChosen ? Color(nsColor: .systemBlue).opacity(0.30) : Color.white.opacity(isHovered ? 0.08 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { inside in
            isHovered = inside
            hovering?(inside)
        }
        .onDisappear {
            if isHovered { hovering?(false) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: isChosen)
    }
}

/// "1280 × 720": a size in whole pixels.
func formattedSize(width: Double, height: Double) -> String {
    "\(Int(width.rounded())) × \(Int(height.rounded()))"
}
