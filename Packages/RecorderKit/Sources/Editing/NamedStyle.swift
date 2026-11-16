// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A style the user saved with a name (1c design §8): what the default style of 1b kept (the stage, the whole cursor and
/// the zoom's settings, `look`) and the camera's look (mirror, border, shadow, the project's layout with its split, and
/// its own `sizeReference`). Never the bubble's shape, size or place, the aspect, the frame rate, the audio nor a block.
///
/// Encoded as a `.tomastyle`'s `style.json` holds it, without its `version` (plan decision 29): `camera`, `id`, `name`
/// and the look as `style`.
public struct NamedStyle: Codable, Equatable, Sendable {
    /// 8 lowercase hex digits, the name of its package `<id>.tomastyle`; `tomaStyleID` for Toma's style, never saved.
    public var id: String
    /// What the user called it; the app names Toma's style.
    public var name: String
    public var look: DefaultStyle
    public var camera: CameraLook

    public init(id: String, name: String, look: DefaultStyle, camera: CameraLook) {
        self.id = id
        self.name = name
        self.look = look
        self.camera = camera
    }

    /// The id of Toma's style, which no package has: it is not 8 hex digits.
    public static let tomaStyleID = "toma"

    /// Toma's style (1c design §8): Toma's look and the camera of a new project, measured against the short side.
    public static func toma(name: String) -> NamedStyle {
        NamedStyle(id: tomaStyleID, name: name, look: .toma, camera: .newProjects)
    }

    private enum CodingKeys: String, CodingKey {
        case camera, id, name
        case look = "style"
    }
}
