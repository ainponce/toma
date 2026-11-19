// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// One of the Frame tab's frames (phase 2 design §6.7), in the order of its tiles: none, a generic macOS window, or a
/// device around the screen.
public enum FrameChoice: Equatable, Sendable, CaseIterable {
    case none, macWindow, iPhone, iPad, macBook

    /// The choice `frame` is.
    public init(_ frame: WindowFrame) {
        switch frame {
        case .none: self = .none
        case .macWindow: self = .macWindow
        case let .device(device):
            switch device.model {
            case .iPhone: self = .iPhone
            case .iPad: self = .iPad
            case .macBook: self = .macBook
            }
        }
    }

    /// The device it draws; `nil` for none and the window.
    public var device: DeviceModel? {
        switch self {
        case .none, .macWindow: nil
        case .iPhone: .iPhone
        case .iPad: .iPad
        case .macBook: .macBook
        }
    }

    /// What choosing it puts in `style.frame` when the document has `current`: `current` itself when it is this choice
    /// already (a window keeps its title and buttons); a new window dark, untitled and with its buttons (design §5.4); a
    /// device in the finish of the device or the window there, dark after none (design §6.7).
    public func frame(from current: WindowFrame) -> WindowFrame {
        if FrameChoice(current) == self { return current }
        switch self {
        case .none:
            return .none
        case .macWindow:
            return .macWindow(appearance: .dark, title: "", buttons: true)
        case .iPhone, .iPad, .macBook:
            let finish: FrameAppearance
            switch current {
            case .none: finish = .dark
            case let .macWindow(appearance, _, _): finish = appearance
            case let .device(device): finish = device.finish
            }
            return .device(DeviceFrame(model: device ?? .iPhone, finish: finish))
        }
    }
}

/// Whether the Frame tab offers Follow the Cursor (phase 2 design §6.5), and why not.
public enum ReframeOffer: Equatable, Sendable {
    case offered
    /// The content is not `ReframePath.offeredFactor` times as wide as the output, in aspect.
    case notWideEnough
    /// A take of an iPhone or iPad (design §7.6), which records no cursor: nothing would move the window.
    case noCursor
    /// The editor has not read the content's ratio yet.
    case unknown
}

/// The rules of the Frame tab (phase 2 design §6.5 and §6.7), as pure functions of the document's values.
public enum FrameTabRules {
    /// Whether Follow the Cursor is offered for content of `contentRatio` (`StageLayout.contentRatio`) in an output of
    /// `outputRatio` (`ReframePath.isOffered`); never for a device take.
    public static func reframeOffer(contentRatio: Double?, outputRatio: Double, isDeviceTake: Bool) -> ReframeOffer {
        if isDeviceTake { return .noCursor }
        guard let contentRatio else { return .unknown }
        return ReframePath.isOffered(contentRatio: contentRatio, outputRatio: outputRatio) ? .offered : .notWideEnough
    }

    /// Whether the control of the screen's framing can be used: where it is offered, and wherever the document follows
    /// the cursor already, so it can go back to Fit (a format changed under it, or a style brought it: the render still
    /// follows the cursor wherever the screen is wider than the room).
    public static func reframeIsEnabled(offer: ReframeOffer, reframe: Reframe) -> Bool {
        offer == .offered || reframe == .followCursor
    }

    /// `frame` with `finish`; `nil` for a frame that is not a device.
    public static func frame(_ frame: WindowFrame, finish: FrameAppearance) -> WindowFrame? {
        guard case let .device(device) = frame else { return nil }
        return .device(DeviceFrame(model: device.model, finish: finish))
    }

    /// Whether `style`'s frame is drawn: following the cursor, the screen is cut and no frame is (design §6.5).
    public static func frameIsDrawn(_ style: StageStyle) -> Bool {
        style.reframe == .fit
    }
}
