// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import ProjectFormat

/// What the sheet of the findings of the sensitive data search shows and adds (phase 2 design §7.2): the blocks the scan's
/// findings make (`PrivacyFinding.block(id:)`, one per finding, in the findings' order), grouped by kind, each with its
/// box, all checked; "Blur N" adds the checked ones in one step (`PrivacyCommands.addAuto`).
///
/// With the document they are for:
/// - A finding the output does not show (all of it in a cut: the scan looks at the whole take, so a later trim needs no
///   new search) is in no group and never added.
/// - A finding whose block the document already has (the same take, span, place and kind: what an earlier "Blur N" of
///   the same scan added, whatever was changed since of its effect) is hidden already: it is listed but starts
///   unchecked, so searching again and blurring again never doubles a block.
public struct FindingsSheetRules: Equatable, Sendable {
    /// The findings of one kind (`PrivacyBlock.origin`), as indices of `blocks`, in the order of their start.
    public struct Group: Equatable, Sendable {
        public var origin: PrivacyOrigin
        public var indices: [Int]

        public init(origin: PrivacyOrigin, indices: [Int]) {
            self.origin = origin
            self.indices = indices
        }
    }

    /// The order of the groups: emails, phones, cards, keys and tokens, faces.
    public static let kinds: [PrivacyOrigin] = [.email, .phone, .card, .secret, .face]

    /// The findings' blocks, as given.
    public let blocks: [PrivacyBlock]
    /// The kinds with findings listed, in `kinds`' order; none is empty.
    public let groups: [Group]
    /// The findings listed that the document has a block of already.
    public let alreadyHidden: Set<Int>
    /// The findings "Blur N" adds: at first every one listed but those `alreadyHidden`.
    public private(set) var checked: Set<Int>
    /// Where the output shows each finding, the cuts inside it closed; `nil` without a document.
    private let outputs: [Range<Int64>?]

    public init(blocks: [PrivacyBlock], document: EditDocument? = nil) {
        self.blocks = blocks
        outputs = document.map { doc in blocks.map { PrivacyCommands.outputRange(of: $0, in: doc) } } ?? blocks.map { _ in nil }
        let listed = blocks.indices.filter { [outputs] k in document == nil || outputs[k] != nil }
            .sorted { (blocks[$0].start, $0) < (blocks[$1].start, $1) }
        groups = Self.kinds.compactMap { kind in
            let indices = listed.filter { blocks[$0].origin == kind }
            return indices.isEmpty ? nil : Group(origin: kind, indices: indices)
        }
        let grouped = Set(groups.flatMap(\.indices))
        let present = (document?.privacy.blocks ?? []).filter { $0.origin != .manual }
        alreadyHidden = grouped.filter { k in present.contains { Self.hides($0, blocks[k]) } }
        checked = grouped.subtracting(alreadyHidden)
    }

    /// How many blocks "Blur N" adds.
    public var addCount: Int { checked.count }

    /// The checked findings' blocks, in `blocks`' order.
    public var chosen: [PrivacyBlock] {
        blocks.indices.filter(checked.contains).map { blocks[$0] }
    }

    public func isChecked(_ index: Int) -> Bool {
        checked.contains(index)
    }

    /// Where the output shows finding `index`, the cuts inside it closed; `nil` if it shows nothing of it, or without a
    /// document.
    public func output(of index: Int) -> Range<Int64>? {
        outputs.indices.contains(index) ? outputs[index] : nil
    }

    /// Checks finding `index`, or unchecks it; an index of no group's finding is left alone.
    public mutating func toggle(_ index: Int) {
        guard groups.contains(where: { $0.indices.contains(index) }) else { return }
        if checked.remove(index) == nil { checked.insert(index) }
    }

    /// Whether `block`, of the document, is what `finding`'s block would add.
    private static func hides(_ block: PrivacyBlock, _ finding: PrivacyBlock) -> Bool {
        block.origin == finding.origin && block.take == finding.take && block.start == finding.start
            && block.end == finding.end && block.rect == finding.rect && block.keys == finding.keys
    }
}
