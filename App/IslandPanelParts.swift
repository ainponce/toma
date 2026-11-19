// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import SwiftUI

// The open island's columns and rows, shared by what each mode shows in them.

/// A column of the open island: a card with its content from the top, its title row the same height in
/// every column so what follows lines up across them.
struct Column<Content: View>: View {
    let width: Double
    @ViewBuilder let content: Content

    /// Concentric with the island's bottom corners (34) inside its margins.
    static var radius: Double { 16 }
    /// Between the sections of a card.
    static var spacing: Double { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) { content }
            .padding(12)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
            }
    }
}

/// A card's title in small capitals, with its symbol; `accessory` (a switch) at the trailing edge.
struct ColumnTitle<Accessory: View>: View {
    let text: Text
    var icon: String?
    @ViewBuilder var accessory: Accessory

    /// Every card's title row: the height of a mini switch.
    static var height: Double { 18 }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 14)
                }
                text.textCase(.uppercase).tracking(0.6)
            }
            .font(.system(size: 11, weight: .semibold))
            .opacity(0.55)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory
        }
        .frame(height: Self.height)
    }
}

extension ColumnTitle where Accessory == EmptyView {
    init(text: Text, icon: String? = nil) {
        self.init(text: text, icon: icon) { EmptyView() }
    }
}

/// A section's name, over its control.
struct ColumnSubtitle: View {
    let text: Text
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
            text
        }
        .font(.system(size: 11, weight: .medium))
        .opacity(0.55)
    }
}

/// A section of a card: its name (and what goes at its right, such as a meter) close over its controls.
struct ColumnSection<Trailing: View, Content: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ColumnSubtitle(text: title)
                Spacer(minLength: 0)
                trailing
            }
            content
        }
    }
}

extension ColumnSection where Trailing == EmptyView {
    init(title: Text, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// A short note at the bottom of a column.
struct ColumnNote: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 11))
            .lineSpacing(1)
            .opacity(0.55)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row that can be chosen (a display, a window, an area): its title (up to two lines, never cut in the
/// middle) and a smaller line under it, an icon before them if it has one, and a check that grows in once
/// it is chosen (with "Reduce motion", fades in). Brighter under the pointer, darker while pressed.
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
        Button(action: choose) {
            HStack(spacing: 8) {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name).symbolRenderingMode(.hierarchical).font(.system(size: 12)).opacity(0.75)
                        .frame(width: 18)
                case .image(let image):
                    Image(nsImage: image).resizable().frame(width: 18, height: 18)
                case nil:
                    EmptyView()
                }
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        subtitle.font(.system(size: 11)).monospacedDigit().opacity(0.6).lineLimit(1)
                    }
                }
                .multilineTextAlignment(.leading)
                // All the width there is, rather than half of it with a spacer: the title only wraps when it must.
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                    // It grows in; with "Reduce motion" it fades in.
                    .scaleEffect(reduceMotion || isChosen ? 1 : 0.001)
                    .opacity(reduceMotion && !isChosen ? 0 : 1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(ChoiceRowStyle(isChosen: isChosen, isHovered: isHovered))
        .onHover { inside in
            isHovered = inside
            hovering?(inside)
        }
        .onDisappear {
            if isHovered { hovering?(false) }
        }
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: isChosen)
        .animation(.island(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
    }
}

/// A choice row's background: the accent once chosen, a light wash under the pointer, a little more pressed.
private struct ChoiceRowStyle: ButtonStyle {
    let isChosen: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill(isPressed: configuration.isPressed))
            }
            .contentShape(Rectangle())
    }

    private func fill(isPressed: Bool) -> Color {
        if isChosen { return Color.accentColor.opacity(isPressed ? 0.36 : 0.28) }
        if isPressed { return Color.white.opacity(0.12) }
        return Color.white.opacity(isHovered ? 0.07 : 0)
    }
}

/// "1280 × 720": a size in whole pixels.
func formattedSize(width: Double, height: Double) -> String {
    "\(Int(width.rounded())) × \(Int(height.rounded()))"
}
