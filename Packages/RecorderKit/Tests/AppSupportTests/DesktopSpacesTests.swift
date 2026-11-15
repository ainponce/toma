// SPDX-License-Identifier: GPL-3.0-or-later
@testable import AppSupport
import Foundation
import Synchronization
import Testing

// MARK: - Fixtures

// What `CGSCopyManagedDisplaySpaces` returns, in the shape of a dump on macOS 26.6.2: every key it had,
// with made-up values (no titles, apps or UUIDs of a real Mac). The parser reads only some of them.

/// An ordinary desktop.
private func desktop(_ id: Int) -> [String: Any] {
    ["ManagedSpaceID": id, "id64": id, "type": 0, "uuid": uuid(id)]
}

/// An app in full screen, or several side by side (Split View): one tile each, in order.
private func fullScreen(_ id: Int, _ tiles: [(app: String, name: String)]) -> [String: Any] {
    let size: [String: Any] = ["Width": 1000.0, "Height": 600.0]
    let tileSpaces: [[String: Any]] = tiles.enumerated().map { index, tile in
        let tileID = id * 10 + index
        return [
            "ManagedSpaceID": tileID, "id64": tileID, "type": 5, "uuid": uuid(tileID), "pid": 400 + tileID, "fs_wid": 700 + tileID,
            "appName": tile.app, "name": tile.name, "TileType": "window", "TileWindowID": 700 + tileID,
            "TileLimitedClipping": false, "com.apple.appkit.disablemcexit": false, "fromSpace": uuid(1),
            "TileRect": ["X": 0.0, "Y": 0.0, "Width": 1000.0, "Height": 600.0],
            "SizeConstraints": ["Max": size, "Min": size, "Preferred": size],
        ]
    }
    return [
        "ManagedSpaceID": id, "id64": id, "type": 4, "uuid": uuid(id), "pid": 400 + id, "fs_wid": 700 + id,
        "TileLayoutManager": [
            "Age": 1.0, "ConfigAge": 1.0, "Inter-Tile Spacing": ["Width": 0.0, "Height": 0.0],
            "Layout Rect": ["X": 0.0, "Y": 0.0, "Width": 1000.0, "Height": 600.0], "Max Tile Config": size,
            "PreferredLayout": [["DisplaySize": size, "FirstTileSize": size]],
            "ReservedArea": ["Top": 0.0, "Bottom": 0.0, "Left": 0.0, "Right": 0.0],
            "TileSpaces": tileSpaces,
        ] as [String: Any],
        "WallSpace": ["ManagedSpaceID": id * 100, "id64": id * 100, "type": 6, "uuid": uuid(id * 100)],
    ]
}

/// A display's entry: `current` is one of `spaces`, whole, as the dump has it.
private func display(_ identifier: String, current: Int, _ spaces: [[String: Any]]) -> [String: Any] {
    let currentSpace = spaces.first { $0["ManagedSpaceID"] as? Int == current } ?? desktop(current)
    return ["Display Identifier": identifier, "Current Space": currentSpace, "Spaces": spaces]
}

private func uuid(_ n: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012d", n)
}

private let displayA = "00000000-0000-0000-0000-00000000000A"
private let displayB = "00000000-0000-0000-0000-00000000000B"

@MainActor
private func makeJumper(trusted: Bool, shortcuts: Bool, log: JumpLog) -> SpaceJumper {
    SpaceJumper(
        isTrusted: { trusted }, shortcutsEnabled: { shortcuts }, post: { log.append(.post($0)) },
        sleep: { log.append(.sleep($0)) })
}

/// What a jumper did, in order: each press posted and each wait.
private final class JumpLog: Sendable {
    enum Entry: Equatable { case post(SpaceDirection), sleep(Duration) }
    private let entries = Mutex<[Entry]>([])
    var all: [Entry] { entries.withLock { $0 } }
    func append(_ entry: Entry) { entries.withLock { $0.append(entry) } }
}

/// Keys and the types of their values, one per line; an array shows each distinct shape of its elements once.
private func shape(of value: Any, indent: String) -> String {
    switch value {
    case let dictionary as [String: Any]:
        return dictionary.keys.sorted().map { key in
            let child = dictionary[key]!
            let nested = shape(of: child, indent: indent + "  ")
            return "\(indent)\(key): \(typeName(child))" + (nested.isEmpty ? "" : "\n" + nested)
        }.joined(separator: "\n")
    case let array as [Any]:
        var seen: [String] = []
        for element in array {
            let lines = "\(indent)- \(typeName(element))\n" + shape(of: element, indent: indent + "  ")
            if !seen.contains(lines) { seen.append(lines) }
        }
        return seen.joined(separator: "\n")
    default:
        return ""
    }
}

private func typeName(_ value: Any) -> String {
    switch value {
    case is String: "String"
    case let number as NSNumber: CFGetTypeID(number) == CFBooleanGetTypeID() ? "Bool" : "Number"
    case let array as [Any]: "Array (\(array.count))"
    case is [String: Any]: "Dictionary"
    default: "\(type(of: value))"
    }
}

/// Whether each loss of the keyboard, at `times` in order, is the desktop's.
private func losses(_ grace: inout SpaceSwitchGrace, at times: Duration...) -> [Bool] {
    times.map { grace.keyboardLost(at: $0) }
}

@Suite struct DesktopSpacesTests {
    // MARK: - Parsing

    @Test func parsesDesktopsAndFullScreenAppsInMissionControlOrder() throws {
        let raw: NSArray = [
            display(displayA, current: 2, [desktop(1), desktop(2), fullScreen(3, [("Keynote", "Lanzamiento.key")]), desktop(4)]),
        ]
        let parsed = try #require(DesktopSpaces.parse(raw))
        #expect(parsed == [
            DisplaySpaces(displayIdentifier: displayA, spaces: [
                DesktopSpace(id: 1, label: .desktop(number: 1), isCurrent: false),
                DesktopSpace(id: 2, label: .desktop(number: 2), isCurrent: true),
                DesktopSpace(id: 3, label: .fullScreen(app: "Keynote", windowTitle: nil), isCurrent: false),
                DesktopSpace(id: 4, label: .desktop(number: 3), isCurrent: false),
            ]),
        ])

        // The current one in full screen (its own entry has a `WallSpace` of type 6, which is not checked).
        let onKeynote = try #require(DesktopSpaces.parse([display(displayA, current: 3, [desktop(1), fullScreen(3, [("Keynote", "")])])]))
        #expect(onKeynote[0].spaces.map(\.isCurrent) == [false, true])
    }

    @Test func aSingleDesktopHasNoNumber() {
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1)])])?[0].spaces
            == [DesktopSpace(id: 1, label: .desktop(number: nil), isCurrent: true)])
        // One desktop and an app in full screen: still the only desktop.
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1), fullScreen(2, [("Keynote", "A")])])])?[0].spaces.map(\.label)
            == [.desktop(number: nil), .fullScreen(app: "Keynote", windowTitle: nil)])
    }

    @Test func fullScreenAppsWithSeveralWindowsShowTheTitle() {
        let raw = [
            display(displayA, current: 1, [
                desktop(1), fullScreen(2, [("Safari", "A")]), fullScreen(3, [("Safari", "B")]), fullScreen(4, [("Safari", "")]),
                fullScreen(5, [("Keynote", "Lanzamiento.key")]),
            ]),
        ]
        #expect(DesktopSpaces.parse(raw)?[0].spaces.map(\.label) == [
            .desktop(number: nil),
            .fullScreen(app: "Safari", windowTitle: "A"),
            .fullScreen(app: "Safari", windowTitle: "B"),
            .fullScreen(app: "Safari", windowTitle: nil),
            .fullScreen(app: "Keynote", windowTitle: nil),
        ])
    }

    @Test func splitViewNamesEveryApp() {
        let raw = [
            display(displayA, current: 1, [
                desktop(1), fullScreen(2, [("Safari", "A"), ("Notas", "B")]), fullScreen(3, [("Safari", "C")]),
            ]),
        ]
        // The Safari in Split View does not count: the one Safari in full screen has no title.
        #expect(DesktopSpaces.parse(raw)?[0].spaces.map(\.label) == [
            .desktop(number: nil), .splitView(apps: ["Safari", "Notas"]), .fullScreen(app: "Safari", windowTitle: nil),
        ])
    }

    @Test func eachDisplayHasItsOwnDesktops() {
        let raw = [
            display(displayA, current: 2, [desktop(1), desktop(2)]),
            display(displayB, current: 3, [desktop(3), fullScreen(4, [("Safari", "A")]), fullScreen(5, [("Safari", "B")])]),
        ]
        let parsed = DesktopSpaces.parse(raw)
        #expect(parsed?.map(\.displayIdentifier) == [displayA, displayB])
        #expect(parsed?[0].spaces.map(\.label) == [.desktop(number: 1), .desktop(number: 2)])
        // Numbered and titled on its own display only.
        #expect(parsed?[1].spaces.map(\.label) == [
            .desktop(number: nil), .fullScreen(app: "Safari", windowTitle: "A"), .fullScreen(app: "Safari", windowTitle: "B"),
        ])
        #expect(parsed?[1].spaces.map(\.isCurrent) == [true, false, false])
    }

    @Test func unexpectedShapeGivesNoList() {
        // Not an array (of dictionaries).
        #expect(DesktopSpaces.parse(42) == nil)
        #expect(DesktopSpaces.parse(["Spaces"]) == nil)
        // A display without its spaces, or without its current one.
        var noSpaces = display(displayA, current: 1, [desktop(1)])
        noSpaces["Spaces"] = nil
        #expect(DesktopSpaces.parse([noSpaces]) == nil)
        var noCurrent = display(displayA, current: 1, [desktop(1)])
        noCurrent["Current Space"] = nil
        #expect(DesktopSpaces.parse([noCurrent]) == nil)
        var noIdentifier = display(displayA, current: 1, [desktop(1)])
        noIdentifier["Display Identifier"] = 7
        #expect(DesktopSpaces.parse([noIdentifier]) == nil)
        // A kind of desktop it does not know, among others it does.
        var unknown = desktop(2)
        unknown["type"] = 7
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1), unknown])]) == nil)
        // An ID that is not a number.
        var textID = desktop(2)
        textID["ManagedSpaceID"] = "2"
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1), textID])]) == nil)
        // An app in full screen without its tiles, or without their names.
        var noTiles = fullScreen(2, [("Keynote", "A")])
        noTiles["TileLayoutManager"] = nil
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1), noTiles])]) == nil)
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1), fullScreen(2, [])])]) == nil)
        var noAppName = fullScreen(2, [("Keynote", "A")])
        var layout = noAppName["TileLayoutManager"] as! [String: Any]
        var tiles = layout["TileSpaces"] as! [[String: Any]]
        tiles[0]["appName"] = nil
        layout["TileSpaces"] = tiles
        noAppName["TileLayoutManager"] = layout
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1), noAppName])]) == nil)
        // Nothing wrong: a list.
        #expect(DesktopSpaces.parse([display(displayA, current: 1, [desktop(1), fullScreen(2, [("Keynote", "A")])])]) != nil)
    }

    @Test func sharedSpacesUseTheMainEntry() throws {
        let main = try #require(DesktopSpaces.parse([display("Main", current: 1, [desktop(1), desktop(2)])]))
        #expect(DesktopSpaces.spaces(forDisplayUUID: "ABC", in: main) == main[0])

        let separate = try #require(DesktopSpaces.parse([
            display(displayA, current: 1, [desktop(1)]), display(displayB, current: 2, [desktop(2), desktop(3)]),
        ]))
        #expect(DesktopSpaces.spaces(forDisplayUUID: displayB, in: separate) == separate[1])
        #expect(DesktopSpaces.spaces(forDisplayUUID: "ABC", in: separate) == nil)
        // One entry that is not "Main" is that display's only.
        #expect(DesktopSpaces.spaces(forDisplayUUID: "ABC", in: [separate[0]]) == nil)
        #expect(DesktopSpaces.spaces(forDisplayUUID: "ABC", in: []) == nil)
    }

    // MARK: - The reader

    @Test func missingSymbolsGiveNoList() {
        #expect(SpacesReader(copySpaces: nil).snapshot() == nil)
        #expect(SpacesReader(copySpaces: { 42 }).snapshot() == nil)
        #expect(SpacesReader(copySpaces: { nil }).snapshot() == nil)
        let reader = SpacesReader(copySpaces: { [display(displayA, current: 1, [desktop(1)])] as NSArray })
        #expect(reader.snapshot()?.first?.spaces == [DesktopSpace(id: 1, label: .desktop(number: nil), isCurrent: true)])
    }

    /// Reads this Mac's desktops (no permission needed: the reader only reads). Prints only the shape of
    /// what `CGSCopyManagedDisplaySpaces` returns, its keys and the types of their values, never the values
    /// themselves: they have window titles.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RECORDER_INTEGRATION"] == "1"))
    func liveSpacesParseOnThisMac() throws {
        let raw = try #require(SpacesReader.live.copySpaces?(), "the reader found its functions")
        print("Managed display spaces:\n\(shape(of: raw, indent: ""))")
        let snapshot = try #require(SpacesReader.live.snapshot())
        #expect(!snapshot.isEmpty)
        for display in snapshot {
            #expect(!display.spaces.isEmpty)
            #expect(display.spaces.count { $0.isCurrent } == 1)
        }
    }

    // MARK: - Jumping

    @Test func jumpPlanCountsPressesAndDirection() {
        #expect(SpaceJump.presses(from: 0, to: 3).map { [$0.direction: $0.count] } == [.right: 3])
        #expect(SpaceJump.presses(from: 3, to: 1).map { [$0.direction: $0.count] } == [.left: 2])
        #expect(SpaceJump.presses(from: 2, to: 2) == nil)
    }

    @MainActor @Test func jumpWithoutAccessibilityExplainsInsteadOfPosting() async {
        let log = JumpLog()
        let jumper = makeJumper(trusted: false, shortcuts: true, log: log)
        #expect(await jumper.jump(from: 0, to: 2) == .needsAccessibility)
        #expect(await jumper.step(.left) == .needsAccessibility)
        #expect(log.all.isEmpty)
        // Nothing to post: the current desktop needs no permission.
        #expect(await jumper.jump(from: 1, to: 1) == .alreadyThere)
    }

    @MainActor @Test func jumpWithShortcutsOffExplainsInsteadOfPosting() async {
        for trusted in [true, false] {
            let log = JumpLog()
            let jumper = makeJumper(trusted: trusted, shortcuts: false, log: log)
            #expect(await jumper.jump(from: 0, to: 2) == .shortcutsOff)
            #expect(await jumper.step(.right) == .shortcutsOff)
            #expect(log.all.isEmpty)
        }
    }

    @MainActor @Test func jumpPostsEachPressWithAPause() async {
        #expect(SpaceJumper.pressInterval == .milliseconds(150))
        let log = JumpLog()
        let jumper = makeJumper(trusted: true, shortcuts: true, log: log)
        #expect(await jumper.jump(from: 0, to: 2) == .jumped(presses: 2))
        #expect(log.all == [.post(.right), .sleep(.milliseconds(150)), .post(.right)])
        #expect(await jumper.jump(from: 1, to: 1) == .alreadyThere)
        #expect(log.all.count == 3)

        let left = JumpLog()
        let stepper = makeJumper(trusted: true, shortcuts: true, log: left)
        #expect(await stepper.step(.left) == .jumped(presses: 1))
        #expect(await stepper.jump(from: 3, to: 0) == .jumped(presses: 3))
        #expect(left.all == [.post(.left), .post(.left), .sleep(.milliseconds(150)), .post(.left), .sleep(.milliseconds(150)), .post(.left)])
    }

    @MainActor @Test func aCancelledJumpStopsPosting() async {
        let log = JumpLog()
        let jumper = SpaceJumper(
            isTrusted: { true }, shortcutsEnabled: { true }, post: { log.append(.post($0)) },
            sleep: { _ in throw CancellationError() })
        #expect(await jumper.jump(from: 0, to: 3) == .jumped(presses: 1))
        #expect(log.all == [.post(.right)])
    }

    @Test func shortcutsFollowTheSystemPreferences() {
        /// An entry of `AppleSymbolicHotKeys` as macOS writes it: only `enabled` once switched without new keys.
        func entry(enabled: Bool, key: Int? = nil, modifiers: Int = 0x84_0000) -> [String: Any] {
            guard let key else { return ["enabled": enabled] }
            return ["enabled": enabled, "value": ["parameters": [65535, key, modifiers], "type": "standard"]]
        }
        let control = 0x4_0000, option = 0x8_0000, command = 0x10_0000, fn = 0x80_0000
        // Never changed: macOS's defaults, on. With no shortcut ever customized there is no value at all.
        #expect(SpaceJumper.shortcutsState(in: nil) == .on)
        #expect(SpaceJumper.shortcutsState(in: [String: Any]()) == .on)
        // Other ⌃fn-arrow shortcuts (window tiling, the shifted variants) do not matter.
        let others: [String: Any] = [
            "80": entry(enabled: true, key: 123, modifiers: 0xA4_0000), "82": entry(enabled: true, key: 124, modifiers: 0xA4_0000),
            "248": entry(enabled: true, key: 123, modifiers: control | fn), "249": entry(enabled: false, key: 124, modifiers: control | fn),
            "16": ["enabled": false],
        ]
        #expect(SpaceJumper.shortcutsState(in: others) == .on)
        // On, without their keys (as on macOS 26.6.2), or with them, with or without fn.
        #expect(SpaceJumper.shortcutsState(in: ["79": entry(enabled: true), "81": entry(enabled: true)]) == .on)
        #expect(SpaceJumper.shortcutsState(in: ["79": entry(enabled: true, key: 123), "81": entry(enabled: true, key: 124)]) == .on)
        #expect(SpaceJumper.shortcutsState(in: ["79": entry(enabled: true, key: 123, modifiers: control)]) == .on)
        // "Move left a space" off; "Move right a space" moved to another key; the modifiers changed.
        var off = others
        off["79"] = entry(enabled: false)
        #expect(SpaceJumper.shortcutsState(in: off) == .off)
        #expect(SpaceJumper.shortcutsState(in: ["79": entry(enabled: false, key: 123)]) == .off)
        #expect(SpaceJumper.shortcutsState(in: ["81": entry(enabled: true, key: 125)]) == .off)
        #expect(SpaceJumper.shortcutsState(in: ["79": entry(enabled: true, key: 123, modifiers: control | option | fn)]) == .off)
        #expect(SpaceJumper.shortcutsState(in: ["81": entry(enabled: true, key: 124, modifiers: command | fn)]) == .off)
        // A value of another shape: unknown, and nothing is posted either.
        #expect(SpaceJumper.shortcutsState(in: ["79", "81"]) == .unknown)
        #expect(SpaceJumper.shortcutsState(in: 42) == .unknown)
        #expect(SpaceJumper.shortcutsState(in: ["79": 1]) == .unknown)
        #expect(SpaceJumper.shortcutsState(in: ["79": ["value": ["parameters": [65535, 123, control]]]]) == .unknown)
        #expect(SpaceJumper.shortcutsState(in: ["79": ["enabled": "yes"]]) == .unknown)
        #expect(SpaceJumper.shortcutsState(in: ["81": ["enabled": true, "value": [65535, 124, control]]]) == .unknown)
        #expect(SpaceJumper.shortcutsState(in: ["81": ["enabled": true, "value": ["parameters": [65535, 124]]]]) == .unknown)
        #expect(SpaceJumper.shortcutsState(in: ["81": ["enabled": true, "value": ["parameters": ["a", "b", "c"]]]]) == .unknown)
        // Unknown wins over off: either way nothing is posted.
        #expect(SpaceJumper.shortcutsState(in: ["79": entry(enabled: false), "81": 1]) == .unknown)
    }

    /// Reads macOS's shortcuts preferences on this Mac (no permission needed). Prints only the state.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RECORDER_INTEGRATION"] == "1"))
    func liveShortcutsAreReadOnThisMac() {
        let state = SpaceJumper.readShortcuts()
        print("Move left / right a space: \(state)")
        #expect(state != .unknown)
    }

    // MARK: - The desktop changing under the open island

    @Test func aJumpKeepsTheOpenIslandOnceAsItsDesktopComes() {
        #expect(SpaceSwitchGrace.grace == .milliseconds(500) && SpaceSwitchGrace.switchWait == .seconds(1))
        // Nothing switching: losing the keyboard is a click elsewhere.
        var idle = SpaceSwitchGrace()
        #expect(losses(&idle, at: .seconds(10)) == [false])

        // While a jump posts, and until 1 s after its last press: the first loss is the desktop's, the next a click.
        var jump = SpaceSwitchGrace()
        jump.jumpBegan()
        #expect(losses(&jump, at: .seconds(10), .seconds(10)) == [true, false])
        var landing = SpaceSwitchGrace()
        landing.jumpBegan()
        landing.jumpEnded(posted: true, at: .seconds(10))
        #expect(losses(&landing, at: .milliseconds(10_999), .milliseconds(10_999)) == [true, false])
        var late = SpaceSwitchGrace()
        late.jumpBegan()
        late.jumpEnded(posted: true, at: .seconds(10))
        #expect(losses(&late, at: .seconds(11)) == [false])
        // A jump that posted nothing (no permission, shortcuts off, already there) switches nothing.
        var nothing = SpaceSwitchGrace()
        nothing.jumpBegan()
        nothing.jumpEnded(posted: false, at: .seconds(10))
        #expect(losses(&nothing, at: .milliseconds(10_100)) == [false])
    }

    @Test func aDesktopChangeKeepsTheOpenIslandFor500ms() {
        // ⌃→ from the keyboard, or each desktop a jump goes through: one loss forgiven per change.
        var change = SpaceSwitchGrace()
        change.spaceChanged(at: .seconds(5))
        #expect(losses(&change, at: .milliseconds(5_400), .milliseconds(5_450)) == [true, false])
        change.spaceChanged(at: .seconds(6))
        #expect(losses(&change, at: .milliseconds(6_499)) == [true])
        var over = SpaceSwitchGrace()
        over.spaceChanged(at: .seconds(5))
        #expect(losses(&over, at: .milliseconds(5_500)) == [false])
        // A jump of several desktops: a loss forgiven for each desktop it lands on, and for its last press.
        var steps = SpaceSwitchGrace()
        steps.jumpBegan()
        steps.spaceChanged(at: .seconds(1))
        #expect(losses(&steps, at: .milliseconds(1_100)) == [true])
        steps.spaceChanged(at: .milliseconds(1_150))
        steps.jumpEnded(posted: true, at: .milliseconds(1_300))
        #expect(losses(&steps, at: .milliseconds(1_400), .milliseconds(1_450)) == [true, false])
    }
}
