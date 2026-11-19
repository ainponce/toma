// SPDX-License-Identifier: GPL-3.0-or-later

/// A device drawn around the screen (phase 2 design §6.7): `WindowFrame.device`, encoded flat inside it as
/// `{"finish":"dark","model":"iPhone","type":"device"}`. Drawn in code (`deviceFrame-1`), around the content's aspect.
public struct DeviceFrame: Codable, Equatable, Sendable {
    public var model: DeviceModel
    /// Dark or light.
    public var finish: FrameAppearance

    public init(model: DeviceModel, finish: FrameAppearance) {
        self.model = model
        self.finish = finish
    }
}

public enum DeviceModel: String, Codable, Sendable, CaseIterable {
    case iPhone, iPad, macBook
}
