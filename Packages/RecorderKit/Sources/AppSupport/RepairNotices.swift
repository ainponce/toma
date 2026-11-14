// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A project that cannot be read safely, as recovery reports it.
public struct RepairNotice: Equatable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Which damaged projects the user has already been told about, so the launch check mentions each one
/// once: a project is mentioned again only if its reason changes.
public struct RepairNotices {
    private let defaults: UserDefaults
    static let key = "shownRepairNotices"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The notices among `notices` not shown before, in order.
    public func unseen(_ notices: [RepairNotice]) -> [RepairNotice] {
        let shown = Set(defaults.stringArray(forKey: Self.key) ?? [])
        return notices.filter { !shown.contains(Self.entry($0)) }
    }

    /// Remembers `notices` as shown.
    public func markShown(_ notices: [RepairNotice]) {
        guard !notices.isEmpty else { return }
        var shown = defaults.stringArray(forKey: Self.key) ?? []
        for entry in notices.map(Self.entry) where !shown.contains(entry) {
            shown.append(entry)
        }
        defaults.set(shown, forKey: Self.key)
    }

    private static func entry(_ notice: RepairNotice) -> String {
        "\(notice.path)\n\(notice.reason)"
    }
}
