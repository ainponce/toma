// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Foundation
import ProjectFormat
import Testing

@MainActor @Suite struct LibraryLayoutTests {
    @Test func librarySizeRuleAndPreferences() throws {
        #expect(LibraryLayout.minimumSize == CGSize(width: 760, height: 480))
        // The smaller of 1100 × 720 and 85 % of the visible area.
        #expect(LibraryLayout.initialSize(visible: CGSize(width: 2560, height: 1440)) == CGSize(width: 1100, height: 720))
        #expect(LibraryLayout.initialSize(visible: CGSize(width: 1280, height: 800)) == CGSize(width: 1088, height: 680))
        #expect(LibraryLayout.initialSize(visible: CGSize(width: 1512, height: 944)) == CGSize(width: 1100, height: 720))
        // Never smaller than 760 × 480.
        #expect(LibraryLayout.initialSize(visible: CGSize(width: 800, height: 500)) == CGSize(width: 760, height: 480))
        #expect(LibraryLayout.initialSize(visible: .zero) == LibraryLayout.minimumSize)
        #expect(LibraryLayout.sidebarWidth == 200)
        #expect(LibraryLayout.cardWidth == 200.0...260.0)
        #expect(LibraryLayout.listThumbnail == CGSize(width: 48, height: 27))

        // What the library remembers: nothing saved is the defaults.
        let defaults = LibraryPreferences()
        #expect(defaults.frame == nil && !defaults.asList && defaults.sort == "dateRecorded" && !defaults.ascending)
        #expect(defaults.section == "all")
        #expect(try JSONDecoder().decode(LibraryPreferences.self, from: Data("{}".utf8)) == defaults)
        // A field of another kind takes its default; the others are kept.
        let odd = Data(#"{"asList":"yes","sort":"name","frame":{"x":1}}"#.utf8)
        #expect(try JSONDecoder().decode(LibraryPreferences.self, from: odd) == LibraryPreferences(sort: "name"))
        let chosen = LibraryPreferences(
            frame: Rect(x: 10, y: 20, width: 900, height: 600), asList: true, sort: "size", ascending: true, section: "trash")
        #expect(try JSONDecoder().decode(LibraryPreferences.self, from: JSONEncoder().encode(chosen)) == chosen)

        // Settings saved by 1b, without `library`, read with the defaults; the rest is kept.
        var settings = RecorderSettings(countdownSeconds: 5)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(json.removeValue(forKey: "library") != nil)
        let of1b = try JSONDecoder().decode(RecorderSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(of1b.library == LibraryPreferences() && of1b.countdownSeconds == 5)
        // And what the library chose is saved with the settings.
        let suite = "LibraryLayoutTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suite))
        defer { userDefaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: userDefaults)
        settings.library = chosen
        store.settings = settings
        #expect(SettingsStore(defaults: userDefaults).settings.library == chosen)
    }

    @Test func columnsFitTheirWidth() {
        let spacing = LibraryLayout.cardSpacing
        // As many cards of at least 200 pt as fit, with the spacing between them; never fewer than one.
        #expect(LibraryLayout.columns(width: 0) == 1)
        #expect(LibraryLayout.columns(width: 199) == 1)
        #expect(LibraryLayout.columns(width: 200) == 1)
        #expect(LibraryLayout.columns(width: 400 + spacing - 0.5) == 1)
        #expect(LibraryLayout.columns(width: 400 + spacing) == 2)
        #expect(LibraryLayout.columns(width: 4 * 200 + 3 * spacing) == 4)
        #expect(LibraryLayout.columns(width: .nan) == 1)
        // Each column is then between 200 and 260 pt: wider than that, the cards keep 260 pt.
        #expect(LibraryLayout.columnWidth(width: 400 + spacing, columns: 2) == 200)
        #expect(LibraryLayout.columnWidth(width: 500 + spacing, columns: 2) == 250)
        #expect(LibraryLayout.columnWidth(width: 599 + spacing, columns: 2) == 260)
    }

    @Test func arrowsMoveThroughTheGridAndItsSections() {
        // Two sections, of 5 and 2 cards, in 3 columns:
        //   0 1 2      (Today)
        //   3 4
        //   5 6        (Yesterday)
        let sizes = [5, 2]
        func move(_ index: Int, _ direction: LibraryMove) -> Int {
            LibraryLayout.neighbor(of: index, direction, columns: 3, groupSizes: sizes)
        }
        #expect(move(0, .right) == 1 && move(4, .right) == 5 && move(6, .right) == 6)
        #expect(move(5, .left) == 4 && move(0, .left) == 0)
        #expect(move(1, .down) == 4)
        // Under the last card of a shorter row: the last card of the section.
        #expect(move(2, .down) == 4)
        // From a section's last row to the next section's first, in the same column or its last card.
        #expect(move(3, .down) == 5 && move(4, .down) == 6)
        #expect(move(6, .down) == 6 && move(5, .down) == 5)
        #expect(move(4, .up) == 1 && move(0, .up) == 0)
        // From a section's first row to the previous section's last row.
        #expect(move(5, .up) == 3 && move(6, .up) == 4)
        // A card outside the sections stays where it is.
        #expect(LibraryLayout.neighbor(of: 2, .down, columns: 2, groupSizes: [1]) == 2)
        #expect(LibraryLayout.neighbor(of: 0, .down, columns: 0, groupSizes: []) == 0)
    }

    @Test func selectionWithClicksKeysAndArrows() {
        let order = ["a", "b", "c", "d", "e", "f"]
        var selection = LibrarySelection<String>()
        #expect(selection.selected.isEmpty)

        // A click selects one; ⌘-click adds or takes away; ⇧-click selects from the last clicked one.
        selection.click("b", order: order)
        #expect(selection.selected == ["b"])
        selection.click("d", order: order, toggling: true)
        #expect(selection.selected == ["b", "d"])
        selection.click("b", order: order, toggling: true)
        #expect(selection.selected == ["d"])
        selection.click("f", order: order, extending: true)
        #expect(selection.selected == ["d", "e", "f"])
        selection.click("c", order: order, extending: true)
        #expect(selection.selected == ["c", "d"])

        // ⌘A and Esc.
        selection.selectAll(order)
        #expect(selection.selected == Set(order))
        selection.clear()
        #expect(selection.selected.isEmpty)

        // An arrow with nothing selected selects the first; then it moves the selection; with ⇧ it extends it.
        let sizes = [order.count]
        #expect(selection.move(.right, order: order, columns: 3, groupSizes: sizes) == "a")
        #expect(selection.selected == ["a"])
        #expect(selection.move(.down, order: order, columns: 3, groupSizes: sizes) == "d")
        #expect(selection.selected == ["d"])
        #expect(selection.move(.right, extending: true, order: order, columns: 3, groupSizes: sizes) == "e")
        #expect(selection.move(.right, extending: true, order: order, columns: 3, groupSizes: sizes) == "f")
        #expect(selection.selected == ["d", "e", "f"])
        #expect(selection.move(.up, extending: true, order: order, columns: 3, groupSizes: sizes) == "c")
        #expect(selection.selected == ["c", "d"])
        #expect(selection.move(.left, order: order, columns: 3, groupSizes: sizes) == "b")
        #expect(selection.selected == ["b"])
        #expect(selection.move(.left, order: [], columns: 3, groupSizes: []) == nil)

        // What is no longer shown (a search, another section) is no longer selected.
        selection.click("b", order: order)
        selection.click("e", order: order, toggling: true)
        selection.keep(only: ["a", "e"])
        #expect(selection.selected == ["e"])
        // A selection the table made, as it is; the arrows go on from the card that was last moved to, if it is in it.
        selection.set(["a", "c", "e"])
        #expect(selection.selected == ["a", "c", "e"])
        #expect(selection.move(.right, order: order, columns: 3, groupSizes: sizes) == "f")
        selection.set(["b"])
        #expect(selection.move(.right, order: order, columns: 3, groupSizes: sizes) == "a")
    }
}
