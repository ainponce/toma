// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat

extension CameraShape {
    /// Its name, in the island's camera column and the bubble's menu.
    var title: String {
        switch self {
        case .circle: String(localized: "Circle", comment: "The camera bubble's shape")
        case .roundedSquare: String(localized: "Rounded Square", comment: "The camera bubble's shape")
        case .portrait: String(localized: "Vertical", comment: "The camera bubble's shape: a 3:4 box")
        case .landscape: String(localized: "Horizontal", comment: "The camera bubble's shape: a 16:9 box")
        }
    }

    /// Its SF Symbol.
    var symbol: String {
        switch self {
        case .circle: "circle.fill"
        case .roundedSquare: "square.fill"
        case .portrait: "rectangle.portrait.fill"
        case .landscape: "rectangle.fill"
        }
    }
}

extension CameraStyle {
    /// The sizes the island's camera column and the bubble's menu offer, with their names.
    static var sizes: [(size: Double, title: String)] {
        [
            (small, String(localized: "Small", comment: "The camera bubble's size")),
            (medium, String(localized: "Medium", comment: "The camera bubble's size")),
            (large, String(localized: "Large", comment: "The camera bubble's size")),
        ]
    }
}

/// The camera bubble's context menu (a secondary click on it): every shape and size the island's camera column
/// offers, with the current ones checked. Also during a take, which the island's camera column is not there for:
/// the video follows the change (notch design §5.6), as it follows the bubble let go.
@MainActor
enum CameraBubbleMenu {
    static func make(for setting: CameraSetting) -> NSMenu {
        let menu = NSMenu()
        let style = setting.style
        for shape in CameraShape.allCases {
            menu.addItem(ActionItem(title: shape.title, symbol: shape.symbol, isOn: style.shape == shape) {
                setting.update { $0.shape = shape }
            })
        }
        menu.addItem(.separator())
        for (size, title) in CameraStyle.sizes {
            menu.addItem(ActionItem(title: title, symbol: nil, isOn: style.size == size) {
                setting.update { $0.size = size }
            })
        }
        return menu
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String?, isOn: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = isOn ? .on : .off
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
