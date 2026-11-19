// SPDX-License-Identifier: GPL-3.0-or-later
import Recording

/// Which iPhone or iPad iPhone mode records (`CaptureSelection.deviceUniqueID`) as devices are plugged in and
/// unplugged while the island lists them (design §7.6).
public enum ExternalDeviceChoice {
    /// The device chosen once the devices connected now are known: the chosen one while it is connected; otherwise
    /// the only one connected, as a display is when there is one; otherwise the chosen one stays as it is, since it
    /// may come back (the devices show up a moment after the mode opens) and, with several connected, which one to
    /// record is the user's to say.
    public static func reconciled(_ chosen: String?, connected: [ExternalDeviceInfo]) -> String? {
        if let chosen, connected.contains(where: { $0.uniqueID == chosen }) { return chosen }
        if connected.count == 1 { return connected[0].uniqueID }
        return chosen
    }

    /// What keeps iPhone mode from recording with `connected` listed: no device chosen, or the chosen one is not
    /// connected (no row of the list is marked). `nil` when Record can record it.
    public static func problem(chosen: String?, connected: [ExternalDeviceInfo]) -> TakePlanError? {
        guard let chosen, connected.contains(where: { $0.uniqueID == chosen }) else { return .noDeviceChosen }
        return nil
    }
}

/// What a connected device is, for the symbol of its row.
public enum ExternalDeviceKind: Equatable, Sendable {
    case iPhone, iPad
    /// Neither its model nor its name says.
    case unknown

    /// From the device's model (`iPad13,4`) or, since a screen device's model often only says "iOS Device", its name
    /// ("iPad de Ana").
    public init(_ device: ExternalDeviceInfo) {
        for text in [device.modelID, device.name] {
            if text.range(of: "iPad", options: .caseInsensitive) != nil {
                self = .iPad
                return
            }
            if text.range(of: "iPhone", options: .caseInsensitive) != nil {
                self = .iPhone
                return
            }
        }
        self = .unknown
    }

    /// Its SF Symbol.
    public var symbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .unknown: "ipad.and.iphone"
        }
    }
}
