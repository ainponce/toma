// SPDX-License-Identifier: GPL-3.0-or-later

/// The look of the camera a document starts with: what 1c design §13.3 puts in its "New" column, against the "Legacy" one
/// of a 1b project (its picture not mirrored, no border or shadow, measured against the output's height).
public struct CameraLook: Codable, Equatable, Sendable {
    public var mirror: Bool
    public var border: CameraBorder
    /// 0 to 1.
    public var shadow: Double
    public var layout: CameraLayout
    public var sizeReference: SizeReference

    public init(mirror: Bool, border: CameraBorder, shadow: Double, layout: CameraLayout, sizeReference: SizeReference) {
        self.mirror = mirror
        self.border = border
        self.shadow = shadow
        self.layout = layout
        self.sizeReference = sizeReference
    }

    /// New projects: mirrored, no border (white, 0 wide), shadow 0.4, a Bubble, and measured against the short side.
    public static let newProjects = CameraLook(
        mirror: true, border: .none, shadow: 0.4, layout: CameraLayout(kind: .bubble), sizeReference: .shortSide)

    /// `camera` with this look; its styles, changes, blocks, spring and rules stay as they are.
    public func applied(to camera: CameraPlan) -> CameraPlan {
        var camera = camera
        camera.mirror = mirror
        camera.border = border
        camera.shadow = shadow
        camera.layout = layout
        camera.sizeReference = sizeReference
        return camera
    }
}
