// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat

/// The camera bubble's context menu (a secondary click on it): its shape and its size, with the current ones
/// checked. Also during a take, which the island's camera column is not there for: the video follows the change
/// (notch design §5.6), as it follows the bubble let go.
@MainActor
enum CameraBubbleMenu {
    static func make(for setting: CameraSetting) -> NSMenu {
        let menu = NSMenu()
        let style = setting.style
        let shapes: [(CameraShape, String, String)] = [
            (.circle, String(localized: "Circle", comment: "The camera bubble's shape"), "circle.fill"),
            (.roundedSquare, String(localized: "Rounded Square", comment: "The camera bubble's shape"), "square.fill"),
            (.portrait, String(localized: "Vertical", comment: "The camera bubble's shape: a 3:4 box"), "rectangle.portrait.fill"),
            (.landscape, String(localized: "Horizontal", comment: "The camera bubble's shape: a 16:9 box"), "rectangle.fill"),
        ]
        for (shape, title, symbol) in shapes {
            menu.addItem(ActionItem(title: title, symbol: symbol, isOn: style.shape == shape) {
                setting.update { $0.shape = shape }
            })
        }
        menu.addItem(.separator())
        let sizes: [(Double, String)] = [
            (CameraStyle.small, String(localized: "Small", comment: "The camera bubble's size")),
            (CameraStyle.medium, String(localized: "Medium", comment: "The camera bubble's size")),
            (CameraStyle.large, String(localized: "Large", comment: "The camera bubble's size")),
        ]
        for (size, title) in sizes {
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
