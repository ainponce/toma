// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The three speeds of the zoom's camera that the Zoom tab offers (design §5.4 and §8.3), as springs. AppSupport has no
/// words for the user: the app names them Slow, Medium and Fast.
public enum ZoomSpeed: CaseIterable, Sendable {
    case slow, medium, fast

    /// Damping · response: 1.0 · 1.00, 1.0 · 0.70 and 1.0 · 0.45.
    public var spring: SpringSpec {
        switch self {
        case .slow: SpringSpec(damping: 1.0, response: 1.00)
        case .medium: SpringSpec(damping: 1.0, response: 0.70)
        case .fast: SpringSpec(damping: 1.0, response: 0.45)
        }
    }

    /// The speed whose spring is `spring`; `nil` for any other (a project edited by hand).
    public init?(_ spring: SpringSpec) {
        guard let match = Self.allCases.first(where: { $0.spring == spring }) else { return nil }
        self = match
    }
}

/// What the Zoom tab asks of the take (design §5.4), and the ranges of its bars.
public enum ZoomPanelRules {
    /// "Hold While Typing" needs to know when keys were typed: the take noted at least one `keyActivity`.
    public static func canHoldWhileTyping(events: [InputEvent]) -> Bool {
        events.contains { $0.kind == .keyActivity }
    }

    /// Whether the take recorded the keyboard focus (a `focus` event): "Follow Keyboard Focus" has something to follow.
    public static func hasFocus(events: [InputEvent]) -> Bool {
        events.contains { if case .focus = $0.kind { true } else { false } }
    }

    /// Whether the take has clicks (a `mouseDown`) to make zooms from.
    public static func hasClicks(events: [InputEvent]) -> Bool {
        events.contains { if case .mouseDown = $0.kind { true } else { false } }
    }

    /// The depths of a zoom (`ZoomCommands.depthRange`), in steps of `depthStep`.
    public static let depthRange: ClosedRange<Double> = 1.25...4
    public static let depthStep = 0.05
    /// "Group Clicks Within": 0.5 to 5 s, in steps of 0.1.
    public static let groupGapRange: ClosedRange<Double> = 0.5...5
    /// "Before the Click" and "After the Click": 0 to 2 s and 0 to 3 s, in steps of 0.1.
    public static let leadInRange: ClosedRange<Double> = 0...2
    public static let leadOutRange: ClosedRange<Double> = 0...3
    public static let secondsStep = 0.1
    /// "Loupe Size": the lens's radius, a fraction of the output's short side (`LoupeStyle.radiusRange`, 0.06 to 0.4), in
    /// steps of 0.01 (the panel shows it in % of the short side).
    public static let loupeRadiusRange = LoupeStyle.radiusRange
    public static let loupeRadiusStep = 0.01

    /// The SF Symbol of a zoom mode (phase 3 plan 3b decision 10), in the Zoom tab's menu and on the Zoom track.
    public static func symbol(_ mode: ZoomMode) -> String {
        switch mode {
        case .classic: "plus.magnifyingglass"
        case .highlight: "highlighter"
        case .dim: "sun.min"
        case .loupe: "magnifyingglass.circle"
        }
    }

    /// The symbol a block of the Zoom track shows before its depth: a calm block, its mode's (automatic or not); a Classic
    /// one, the automatic zoom's ✦ if it is automatic and none if it is the user's, as in phase 2.
    public static func trackSymbol(mode: ZoomMode, automatic: Bool) -> String? {
        mode.isCalm ? symbol(mode) : (automatic ? "sparkles" : nil)
    }
}
