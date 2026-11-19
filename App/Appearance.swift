// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import SwiftUI

/// The app's look. Dark unless the user chooses otherwise, as video tools are: the preview's black, the island's glass
/// and the editor's chrome read as one surface, and colors in the video stand out.
enum AppAppearance: String, CaseIterable {
    case dark, system, light

    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

/// The appearance in Settings, saved in the app's defaults (it is the app's chrome, not part of a take's settings) and
/// applied to every window at once.
@MainActor @Observable
final class AppearanceSetting {
    private(set) var value: AppAppearance

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "appearance"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.string(forKey: Self.key).flatMap(AppAppearance.init(rawValue:)) ?? .dark
        apply()
    }

    func set(_ value: AppAppearance) {
        self.value = value
        defaults.set(value.rawValue, forKey: Self.key)
        apply()
    }

    private func apply() {
        NSApplication.shared.appearance = value.nsAppearance
    }

    static func label(for value: AppAppearance) -> Text {
        switch value {
        case .dark: Text("Dark")
        case .system: Text("Match System", comment: "Settings, Appearance: light or dark as the system is")
        case .light: Text("Light")
        }
    }
}
