// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The instant replay (phase 5, milestone 5c): whether Toma keeps the last seconds of the screen to save on a shortcut, and
/// how many. Off by default.
public struct ReplayPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// How many seconds it keeps: one of `validSeconds`.
    public var seconds: Int = 30

    /// The lengths the settings offer.
    public static let validSeconds = [15, 30, 60, 120, 300]

    public init(enabled: Bool = false, seconds: Int = 30) {
        self.enabled = enabled
        self.seconds = seconds
    }

    /// A field missing from what was saved, or a length the settings do not offer, takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReplayPreferences()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        let seconds = (try? container.decodeIfPresent(Int.self, forKey: .seconds)) ?? defaults.seconds
        self.seconds = Self.validSeconds.contains(seconds) ? seconds : defaults.seconds
    }
}
