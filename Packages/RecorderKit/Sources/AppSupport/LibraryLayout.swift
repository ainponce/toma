// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat

/// The measures of the library's window (design §6.1, §6.2), in points, and how the grid's cards are laid out and
/// moved through with the arrows.
public enum LibraryLayout {
    public static let minimumSize = CGSize(width: 760, height: 480)
    /// The largest initial size.
    static let largestInitialSize = CGSize(width: 1100, height: 720)

    /// The size the window opens at on a screen whose visible area (without the menu bar and the Dock) is `visible`: the
    /// smaller of 1100 × 720 and 85 % of it, side by side, in whole points, and never smaller than `minimumSize`.
    public static func initialSize(visible: CGSize) -> CGSize {
        // × 85 / 100 rather than × 0.85, which is not exact.
        func side(_ visible: CGFloat, _ largest: CGFloat, _ minimum: CGFloat) -> CGFloat {
            max(min((visible * 85 / 100).rounded(.down), largest), minimum)
        }
        return CGSize(
            width: side(visible.width, largestInitialSize.width, minimumSize.width),
            height: side(visible.height, largestInitialSize.height, minimumSize.height))
    }

    /// The sidebar's width.
    public static let sidebarWidth = 200.0
    /// How wide a card of the grid is: its columns adapt between these.
    public static let cardWidth: ClosedRange<Double> = 200...260
    /// The thumbnail in the list's Name column.
    public static let listThumbnail = CGSize(width: 48, height: 27)
    /// The space between two cards, across and down.
    public static let cardSpacing = 16.0

    /// How many columns of cards fit in `width` (the grid's, without its margins): as many of `cardWidth`'s least as fit
    /// with `spacing` between them, and at least one.
    public static func columns(width: Double, spacing: Double = cardSpacing) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (cardWidth.lowerBound + spacing)).rounded(.down)))
    }

    /// How wide each of `columns` columns is in `width`: what they share once the spacing is taken, kept in `cardWidth`.
    public static func columnWidth(width: Double, columns: Int, spacing: Double = cardSpacing) -> Double {
        let count = Double(max(columns, 1))
        let share = (width - (count - 1) * spacing) / count
        guard share.isFinite else { return cardWidth.lowerBound }
        return min(max(share, cardWidth.lowerBound), cardWidth.upperBound)
    }

    /// The card an arrow goes to from the card at `index` of a grid of `columns` columns whose sections (the date groups)
    /// have `groupSizes` cards, in order; each section starts a row. Left and right go to the card before and after,
    /// across sections; up and down go to the card above and below in the same column, or, under a shorter row, to the
    /// section's last card, and from a section's first or last row to the nearest row of the section before or after. At
    /// an edge, or for an index outside the sections, the same card.
    public static func neighbor(of index: Int, _ move: LibraryMove, columns: Int, groupSizes: [Int]) -> Int {
        let sizes = groupSizes
        let count = sizes.reduce(0, +)
        guard index >= 0, index < count, sizes.allSatisfy({ $0 > 0 }) else { return index }
        let columns = max(columns, 1)
        switch move {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, count - 1)
        case .up, .down: break
        }
        // The section and the place in it.
        var group = 0
        var start = 0
        while index >= start + sizes[group] {
            start += sizes[group]
            group += 1
        }
        let offset = index - start
        let row = offset / columns
        let column = offset % columns
        let size = sizes[group]
        if move == .down {
            if offset + columns < size { return index + columns }
            if row < (size - 1) / columns { return start + size - 1 }
            guard group + 1 < sizes.count else { return index }
            return start + size + min(column, sizes[group + 1] - 1)
        }
        if row > 0 { return index - columns }
        guard group > 0 else { return index }
        let previous = sizes[group - 1]
        let lastRow = (previous - 1) / columns * columns
        return start - previous + min(lastRow + column, previous - 1)
    }
}

/// Where an arrow key moves the selection.
public enum LibraryMove: Sendable {
    case up, down, left, right
}

/// The cards selected in the library (design §6.2) and how clicks, ⌘A, Esc and the arrows change them, as in the
/// Finder: a click selects one card; ⌘-click adds or takes away one; ⇧-click selects from the last card clicked (the
/// anchor) to this one; an arrow moves from the last card moved to (the cursor), and with ⇧ selects from the anchor to
/// where it goes. `order` is always the cards as they are shown.
public struct LibrarySelection<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var selected: Set<ID> = []
    /// Where a ⇧-click or a ⇧-arrow selects from.
    public private(set) var anchor: ID?
    /// Where the arrows go on from.
    public private(set) var cursor: ID?

    public init() {}

    /// A click on `id`: with `toggling` (⌘) it is added or taken away, with `extending` (⇧) the cards from the anchor
    /// to it are the selection; otherwise it is. The anchor moves only to a card that ends selected by itself or by ⌘.
    public mutating func click(_ id: ID, order: [ID], extending: Bool = false, toggling: Bool = false) {
        if toggling {
            if selected.remove(id) == nil {
                selected.insert(id)
                anchor = id
            }
        } else if extending, let anchor, let range = Self.range(anchor, id, in: order) {
            selected = range
        } else {
            selected = [id]
            anchor = id
        }
        cursor = id
    }

    /// ⌘A: every card shown.
    public mutating func selectAll(_ order: [ID]) {
        selected = Set(order)
        if anchor.map({ !selected.contains($0) }) ?? true { anchor = order.first }
    }

    /// Esc: nothing.
    public mutating func clear() {
        selected = []
        anchor = nil
        cursor = nil
    }

    /// A selection made elsewhere (the list's table): the anchor and the cursor stay if they are in it.
    public mutating func set(_ ids: Set<ID>) {
        selected = ids
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
        if let cursor, !ids.contains(cursor) { self.cursor = nil }
    }

    /// Takes away what is no longer shown (a search, another section).
    public mutating func keep(only shown: Set<ID>) {
        set(selected.intersection(shown))
    }

    /// An arrow: from the cursor to its neighbour (`LibraryLayout.neighbor`), which becomes the selection, or with
    /// `extending` the cards from the anchor to it. With no cursor, the first card. Returns the card moved to, to bring
    /// into view; `nil` when nothing is shown.
    @discardableResult
    public mutating func move(
        _ move: LibraryMove, extending: Bool = false, order: [ID], columns: Int, groupSizes: [Int]
    ) -> ID? {
        guard let first = order.first else { return nil }
        let target: ID
        if let cursor, let index = order.firstIndex(of: cursor) {
            target = order[LibraryLayout.neighbor(of: index, move, columns: columns, groupSizes: groupSizes)]
        } else {
            target = first
        }
        if extending, let anchor, let range = Self.range(anchor, target, in: order) {
            selected = range
        } else {
            selected = [target]
            anchor = target
        }
        cursor = target
        return target
    }

    /// The cards of `order` from `a` to `b`, in either direction; `nil` if one of them is not shown.
    private static func range(_ a: ID, _ b: ID, in order: [ID]) -> Set<ID>? {
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return nil }
        return Set(order[min(i, j)...max(i, j)])
    }
}

/// What the library's window remembers between launches (design §6.1): its frame, the view, the order and the section.
/// `sort` and `section` are the `rawValue`s of the library's `LibrarySort` and `LibrarySection`, which the app reads
/// back (an unknown one is the default).
public struct LibraryPreferences: Codable, Equatable, Sendable {
    /// In global points (`ScreenCoordinates`); `nil` until the window was moved or resized.
    public var frame: Rect?
    public var asList = false
    public var sort = "dateRecorded"
    public var ascending = false
    public var section = "all"

    public init(
        frame: Rect? = nil, asList: Bool = false, sort: String = "dateRecorded", ascending: Bool = false,
        section: String = "all"
    ) {
        self.frame = frame
        self.asList = asList
        self.sort = sort
        self.ascending = ascending
        self.section = section
    }

    /// A field missing from what was saved, or that cannot be read, takes its default; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LibraryPreferences()
        frame = (try? container.decodeIfPresent(Rect.self, forKey: .frame)) ?? defaults.frame
        asList = (try? container.decodeIfPresent(Bool.self, forKey: .asList)) ?? defaults.asList
        sort = (try? container.decodeIfPresent(String.self, forKey: .sort)) ?? defaults.sort
        ascending = (try? container.decodeIfPresent(Bool.self, forKey: .ascending)) ?? defaults.ascending
        section = (try? container.decodeIfPresent(String.self, forKey: .section)) ?? defaults.section
    }
}
