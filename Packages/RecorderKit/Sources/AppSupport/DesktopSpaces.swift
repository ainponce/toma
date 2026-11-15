// SPDX-License-Identifier: GPL-3.0-or-later

/// A desktop (a Space) of a display, as Mission Control names it (notch design §5.5).
public struct DesktopSpace: Equatable, Sendable {
    public enum Label: Equatable, Sendable {
        /// An ordinary desktop: "Desktop 2", or "Desktop" (`nil`) when the display has only one.
        case desktop(number: Int?)
        /// An app in full screen, with its window's title when the app has more than one window in full
        /// screen on that display (and the title is not empty).
        case fullScreen(app: String, windowTitle: String?)
        /// Apps side by side in full screen (Split View), in order.
        case splitView(apps: [String])
    }

    public var id: UInt64
    public var label: Label
    /// The one the display shows now.
    public var isCurrent: Bool

    public init(id: UInt64, label: Label, isCurrent: Bool) {
        self.id = id
        self.label = label
        self.isCurrent = isCurrent
    }
}

/// The desktops of a display, in Mission Control's order.
public struct DisplaySpaces: Equatable, Sendable {
    /// The display's UUID (`SpacesReader.displayUUID(for:)`), or "Main" for the one entry of every display
    /// when "Displays have separate Spaces" is off.
    public var displayIdentifier: String
    public var spaces: [DesktopSpace]

    public init(displayIdentifier: String, spaces: [DesktopSpace]) {
        self.displayIdentifier = displayIdentifier
        self.spaces = spaces
    }
}

/// What the system says about every display's desktops (`SpacesReader`), as a list to show.
public enum DesktopSpaces {
    /// The identifier of the one entry when the displays share their desktops.
    static let sharedIdentifier = "Main"

    /// `managedDisplaySpaces` is an array with a dictionary per display: `"Display Identifier"` (a string),
    /// `"Current Space"` (a whole desktop's dictionary, of which only its `"ManagedSpaceID"` is read) and
    /// `"Spaces"`, the desktops in Mission Control's order, each with `"ManagedSpaceID"` and `"type"` (0 an
    /// ordinary desktop, 4 an app in full screen) and, in full screen, `"TileLayoutManager"` → `"TileSpaces"`,
    /// one dictionary per app with its `"appName"` and its window's `"name"`. Any other shape gives `nil`, the
    /// whole list: a missing key, a value of another type, a desktop of another type (the nested dictionaries
    /// carry types of their own, which are not checked) or an app in full screen without its tiles. With a
    /// desktop missing, a jump would land on another one (plan decision 32).
    public static func parse(_ managedDisplaySpaces: Any) -> [DisplaySpaces]? {
        guard let displays = managedDisplaySpaces as? [[String: Any]] else { return nil }
        var parsed: [DisplaySpaces] = []
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                let current = display["Current Space"] as? [String: Any],
                let currentID = spaceID(current),
                let spaces = display["Spaces"] as? [[String: Any]],
                let kinds = every(spaces, kind(of:))
            else { return nil }
            parsed.append(DisplaySpaces(displayIdentifier: identifier, spaces: label(kinds, currentID: currentID)))
        }
        return parsed
    }

    /// The desktops of the display with this UUID; when the displays share their desktops, the one entry,
    /// "Main". Otherwise `nil`.
    public static func spaces(forDisplayUUID uuid: String, in all: [DisplaySpaces]) -> DisplaySpaces? {
        if let match = all.first(where: { $0.displayIdentifier == uuid }) { return match }
        if all.count == 1, all[0].displayIdentifier == sharedIdentifier { return all[0] }
        return nil
    }

    /// A desktop as the system lists it, before it is named.
    private enum Kind {
        case desktop(id: UInt64)
        /// Each tile's app and window title, in order.
        case fullScreen(id: UInt64, tiles: [(app: String, title: String)])

        var id: UInt64 {
            switch self {
            case .desktop(let id), .fullScreen(let id, _): id
            }
        }
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        (space["ManagedSpaceID"] as? Int).flatMap { UInt64(exactly: $0) }
    }

    private static func kind(of space: [String: Any]) -> Kind? {
        guard let id = spaceID(space), let type = space["type"] as? Int else { return nil }
        switch type {
        case 0:
            return .desktop(id: id)
        case 4:
            guard let layout = space["TileLayoutManager"] as? [String: Any],
                let tileSpaces = layout["TileSpaces"] as? [[String: Any]], !tileSpaces.isEmpty,
                let tiles = every(tileSpaces, tile(of:))
            else { return nil }
            return .fullScreen(id: id, tiles: tiles)
        default:
            return nil
        }
    }

    private static func tile(of tile: [String: Any]) -> (app: String, title: String)? {
        guard let app = tile["appName"] as? String, let title = tile["name"] as? String else { return nil }
        return (app, title)
    }

    /// `transform` of every element, or `nil` if it gives `nil` for any of them.
    private static func every<Element, Result>(_ elements: [Element], _ transform: (Element) -> Result?) -> [Result]? {
        var results: [Result] = []
        results.reserveCapacity(elements.count)
        for element in elements {
            guard let result = transform(element) else { return nil }
            results.append(result)
        }
        return results
    }

    /// Ordinary desktops are numbered among themselves (no number if there is only one); an app in full
    /// screen has its window's title only when it has several windows in full screen (Split View aside).
    private static func label(_ kinds: [Kind], currentID: UInt64) -> [DesktopSpace] {
        let desktopCount = kinds.count { if case .desktop = $0 { true } else { false } }
        var fullScreenCount: [String: Int] = [:]
        for case .fullScreen(_, let tiles) in kinds where tiles.count == 1 {
            fullScreenCount[tiles[0].app, default: 0] += 1
        }
        var number = 0
        return kinds.map { kind in
            let label: DesktopSpace.Label
            switch kind {
            case .desktop:
                number += 1
                label = .desktop(number: desktopCount > 1 ? number : nil)
            case .fullScreen(_, let tiles) where tiles.count == 1:
                let tile = tiles[0]
                let showsTitle = fullScreenCount[tile.app, default: 0] > 1 && !tile.title.isEmpty
                label = .fullScreen(app: tile.app, windowTitle: showsTitle ? tile.title : nil)
            case .fullScreen(_, let tiles):
                label = .splitView(apps: tiles.map(\.app))
            }
            return DesktopSpace(id: kind.id, label: label, isCurrent: kind.id == currentID)
        }
    }
}
