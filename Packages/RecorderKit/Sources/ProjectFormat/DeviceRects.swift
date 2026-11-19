// SPDX-License-Identifier: GPL-3.0-or-later

/// Where each part of a device frame (phase 2 design §6.7, `deviceFrame-1`) goes around its screen, in the coordinates of
/// the screen's rect (a stage's output pixels). Only the parts: the measures that place them are `deviceFrame-1`'s.
public struct DeviceRects: Equatable, Sendable {
    /// The screen inside the device.
    public var screen: Rect
    public var screenCornerRadius: Double
    /// The device's body (the MacBook's lid), band and bezel included.
    public var body: Rect
    public var bodyCornerRadius: Double
    /// The coloured band along the body's edge (the MacBook's lid's rim).
    public var bandWidth: Double
    /// The iPhone's island or the MacBook's notch, drawn over the screen; `nil` without one.
    public var cutout: Rect?
    /// The iPhone's side buttons, outside the body.
    public var buttons: [Rect]
    /// The MacBook's base under the lid; `nil` without one.
    public var base: Rect?
    /// The radius of the base's rounded front.
    public var baseFrontRadius: Double
    /// The union of the body, the buttons and the base: what the device takes on the stage.
    public var bounds: Rect

    public init(
        screen: Rect, screenCornerRadius: Double, body: Rect, bodyCornerRadius: Double, bandWidth: Double, cutout: Rect?,
        buttons: [Rect], base: Rect?, baseFrontRadius: Double, bounds: Rect
    ) {
        self.screen = screen
        self.screenCornerRadius = screenCornerRadius
        self.body = body
        self.bodyCornerRadius = bodyCornerRadius
        self.bandWidth = bandWidth
        self.cutout = cutout
        self.buttons = buttons
        self.base = base
        self.baseFrontRadius = baseFrontRadius
        self.bounds = bounds
    }
}
