// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The edit document of a project, `edit.json` at the package root (format version 3, design §6.2): what the
/// output is made of (the clips of `sequence`) and how it looks. A pure value: the render draws a frame from the
/// package, this document and the output time, and the editor changes it only through the edit log.
///
/// Encoded with `ProjectJSON.encoder()` (keys in alphabetical order, indented, optionals left out, never `null`).
/// Source times are `HostTime` of the take, written as integer nanoseconds. Everything whose look is defined in code
/// is named with its version (`aurora-1`, `ripple-1`, `autoZoom-1`…), and springs and measures are stored as numbers,
/// so an update never changes what a project already saved.
public struct EditDocument: Codable, Equatable, Sendable {
    /// The version of the document this app writes; it refuses a newer one (`decode(_:)`).
    public static let currentVersion = 1

    /// The version of the document within format version 3: 1 in milestone 1b.
    public var documentVersion: Int
    /// The `seq` of the last line of the edit log this document already includes.
    public var logSequence: Int
    public var aspect: Aspect
    /// 24, 25, 30, 50 or 60: the frame grid of the editor and the export sheet's default.
    public var frameRate: Int
    /// The clips, in output order (in 1b, also in source order), never overlapping.
    public var sequence: [Clip]
    public var screens: ScreenPlan
    public var style: StageStyle
    public var cursor: CursorStyle
    public var zoom: ZoomPlan
    public var camera: CameraPlan
    public var audio: AudioPlan

    public init(
        documentVersion: Int,
        logSequence: Int,
        aspect: Aspect,
        frameRate: Int,
        sequence: [Clip],
        screens: ScreenPlan,
        style: StageStyle,
        cursor: CursorStyle,
        zoom: ZoomPlan,
        camera: CameraPlan,
        audio: AudioPlan
    ) {
        self.documentVersion = documentVersion
        self.logSequence = logSequence
        self.aspect = aspect
        self.frameRate = frameRate
        self.sequence = sequence
        self.screens = screens
        self.style = style
        self.cursor = cursor
        self.zoom = zoom
        self.camera = camera
        self.audio = audio
    }

    /// Decodes an encoded document with `ProjectJSON.decoder()`, as `init(from:)` does.
    public static func decode(_ data: Data) throws -> EditDocument {
        try ProjectJSON.decoder().decode(EditDocument.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case documentVersion, logSequence, aspect, frameRate, sequence, screens, style, cursor, zoom, camera, audio
    }

    /// Reads `documentVersion` first, on its own: a document newer than `currentVersion`, which this version may not
    /// be able to decode, throws `EditDocumentError.newerVersion` before anything else is read, wherever it is (a
    /// file of its own or a field of another value, like the `create` line of the edit log). Anything else that does
    /// not decode throws the `DecodingError`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .documentVersion)
        guard version <= Self.currentVersion else { throw EditDocumentError.newerVersion(version) }
        self.init(
            documentVersion: version,
            logSequence: try container.decode(Int.self, forKey: .logSequence),
            aspect: try container.decode(Aspect.self, forKey: .aspect),
            frameRate: try container.decode(Int.self, forKey: .frameRate),
            sequence: try container.decode([Clip].self, forKey: .sequence),
            screens: try container.decode(ScreenPlan.self, forKey: .screens),
            style: try container.decode(StageStyle.self, forKey: .style),
            cursor: try container.decode(CursorStyle.self, forKey: .cursor),
            zoom: try container.decode(ZoomPlan.self, forKey: .zoom),
            camera: try container.decode(CameraPlan.self, forKey: .camera),
            audio: try container.decode(AudioPlan.self, forKey: .audio))
    }
}

public enum EditDocumentError: Error, Equatable, Sendable {
    /// The document's `documentVersion` is newer than `EditDocument.currentVersion`.
    case newerVersion(Int)
}

/// The shape of the output.
public enum Aspect: String, Codable, Sendable {
    case landscape = "16:9"
    case portrait = "9:16"
    case square = "1:1"

    /// Width over height.
    public var ratio: Double {
        switch self {
        case .landscape: 16.0 / 9
        case .portrait: 9.0 / 16
        case .square: 1
        }
    }
}

/// One stretch of a take in the output: its source times `[start, end)` played at `speed`.
public struct Clip: Codable, Equatable, Sendable {
    /// `c-` and 8 hex.
    public var id: String
    public var take: String
    public var start: HostTime
    /// Excluded.
    public var end: HostTime
    /// 0.25 to 16 (`ClipSpeed.range`), and read through `ClipSpeed.clamped(_:)`.
    public var speed: Double

    public init(id: String, take: String, start: HostTime, end: HostTime, speed: Double) {
        self.id = id
        self.take = take
        self.start = start
        self.end = end
        self.speed = speed
    }
}

/// The speeds a clip plays at, and how a speed out of them is read: clamped into the range, and 1 if it is not a
/// number, so a document edited by hand never stops the render. The one rule for every reader of `Clip.speed` (the time
/// map, the sequence commands, the sound's speed), so the picture and the sound never disagree about a clip's length.
public enum ClipSpeed {
    public static let range: ClosedRange<Double> = 0.25...16

    public static func clamped(_ speed: Double) -> Double {
        speed.isNaN ? 1 : min(max(speed, range.lowerBound), range.upperBound)
    }
}

extension EditDocument {
    /// The frame rates a document can have (`frameRate`): the editor's frame grid and the export's choices, each on the
    /// 600 Hz step of the motion (`StepGrid`). A document with another one is never drawn as it is.
    public static let frameRates = [24, 25, 30, 50, 60]
}

/// Which recorded screen is shown: `initial` for each take, then from each change on, its track.
public struct ScreenPlan: Codable, Equatable, Sendable {
    /// The screen track of each take at its start, by take ID.
    public var initial: [String: String]
    public var changes: [ScreenChange]
    /// The planner that made the changes, with its version (`screenFollow-1`), when they were made automatically.
    public var planner: String?

    public init(initial: [String: String], changes: [ScreenChange], planner: String? = nil) {
        self.initial = initial
        self.changes = changes
        self.planner = planner
    }
}

/// From source time `t` of `take` on, screen track `track` is shown.
public struct ScreenChange: Codable, Equatable, Sendable {
    /// `p-` and 8 hex.
    public var id: String
    public var take: String
    public var t: HostTime
    public var track: String
    public var origin: Origin

    public init(id: String, take: String, t: HostTime, track: String, origin: Origin) {
        self.id = id
        self.take = take
        self.t = t
        self.track = track
        self.origin = origin
    }
}

/// Who made an element: a planner, or the user (by hand, or by touching an automatic one).
public enum Origin: String, Codable, Sendable {
    case auto, user
}

/// The stage: what is behind the screen and how the screen sits on it.
public struct StageStyle: Codable, Equatable, Sendable {
    public var background: Background
    /// 0 to 1: σ = value × 0.04 × the output width.
    public var backgroundBlur: Double
    /// Space around the screen on each side, as a fraction of the output width.
    public var padding: Double
    /// Radius of the screen's corners, as a fraction of the output width.
    public var cornerRadius: Double
    /// 0 to 1.
    public var shadow: Double
    public var frame: WindowFrame
    public var screenSampling: ScreenSampling
    public var geometryTransition: GeometryTransition

    public init(
        background: Background,
        backgroundBlur: Double,
        padding: Double,
        cornerRadius: Double,
        shadow: Double,
        frame: WindowFrame,
        screenSampling: ScreenSampling,
        geometryTransition: GeometryTransition
    ) {
        self.background = background
        self.backgroundBlur = backgroundBlur
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.frame = frame
        self.screenSampling = screenSampling
        self.geometryTransition = geometryTransition
    }
}

/// What is behind the screen. Encoded flat with its `type`: `{"type":"gradient","start":[r,g,b,a],"end":[r,g,b,a],
/// "angle":135}`, `{"type":"color","color":[r,g,b,a]}`, `{"type":"wallpaper","wallpaper":"<id>"}`,
/// `{"type":"image","file":"assets/<sha>.<ext>"}` or `{"type":"desktop"}`.
public enum Background: Codable, Equatable, Sendable {
    /// Direction `angle` in degrees as in CSS: 0 goes up, 90 to the right, 135 down and to the right.
    case gradient(start: RGBA, end: RGBA, angle: Double)
    case color(RGBA)
    /// One of Toma's procedural wallpapers, by its versioned ID (`aurora-1`).
    case wallpaper(String)
    /// An image of the user's, copied into the package: its path from the package root, `assets/<sha>.<ext>`.
    case image(file: String)
    /// The desktop picture of the first screen shown, as the take started (`wallpapers/`).
    case desktop

    /// "Toma classic", the violet and teal gradient at 135° of phase 0 and 1a (`StyleV0`).
    public static let tomaClassic = Background.gradient(
        start: RGBA(127.0 / 255, 90.0 / 255, 240.0 / 255, 1), end: RGBA(44.0 / 255, 177.0 / 255, 188.0 / 255, 1), angle: 135)

    private enum CodingKeys: String, CodingKey {
        case type, start, end, angle, color, wallpaper, file
    }

    private enum Kind: String, Codable {
        case gradient, color, wallpaper, image, desktop
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .gradient:
            self = .gradient(
                start: try container.decode(RGBA.self, forKey: .start),
                end: try container.decode(RGBA.self, forKey: .end),
                angle: try container.decode(Double.self, forKey: .angle))
        case .color:
            self = .color(try container.decode(RGBA.self, forKey: .color))
        case .wallpaper:
            self = .wallpaper(try container.decode(String.self, forKey: .wallpaper))
        case .image:
            self = .image(file: try container.decode(String.self, forKey: .file))
        case .desktop:
            self = .desktop
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .gradient(start, end, angle):
            try container.encode(Kind.gradient, forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(angle, forKey: .angle)
        case let .color(color):
            try container.encode(Kind.color, forKey: .type)
            try container.encode(color, forKey: .color)
        case let .wallpaper(id):
            try container.encode(Kind.wallpaper, forKey: .type)
            try container.encode(id, forKey: .wallpaper)
        case let .image(file):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(file, forKey: .file)
        case .desktop:
            try container.encode(Kind.desktop, forKey: .type)
        }
    }
}

/// A colour: sRGB-encoded values from 0 to 1, written to the output as they are. Encoded as `[r, g, b, a]`.
public struct RGBA: Codable, Equatable, Sendable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard container.count == 4 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A colour has 4 components, [r, g, b, a].")
        }
        self.init(
            try container.decode(Double.self), try container.decode(Double.self), try container.decode(Double.self),
            try container.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(r)
        try container.encode(g)
        try container.encode(b)
        try container.encode(a)
    }
}

/// A frame drawn around the screen. Encoded flat with its `type`: `{"type":"none"}` or
/// `{"type":"macWindow","appearance":"dark","title":"…","buttons":true}`.
public enum WindowFrame: Codable, Equatable, Sendable {
    case none
    /// A generic macOS window: its appearance, its title (empty draws none) and whether it has the three buttons.
    case macWindow(appearance: FrameAppearance, title: String, buttons: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, appearance, title, buttons
    }

    private enum Kind: String, Codable {
        case none, macWindow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .none:
            self = .none
        case .macWindow:
            self = .macWindow(
                appearance: try container.decode(FrameAppearance.self, forKey: .appearance),
                title: try container.decode(String.self, forKey: .title),
                buttons: try container.decode(Bool.self, forKey: .buttons))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .type)
        case let .macWindow(appearance, title, buttons):
            try container.encode(Kind.macWindow, forKey: .type)
            try container.encode(appearance, forKey: .appearance)
            try container.encode(title, forKey: .title)
            try container.encode(buttons, forKey: .buttons)
        }
    }
}

public enum FrameAppearance: String, Codable, Sendable {
    case light, dark
}

/// How the screen's frames are sampled when they are drawn smaller than recorded.
public enum ScreenSampling: String, Codable, Sendable {
    /// Bilinear, as in phase 0 and 1a.
    case bilinear
    /// From a mipmapped texture, which does not alias when the screen is drawn much smaller.
    case mipmapped
}

/// How the screen's rect goes from one shape to another (another screen shown, a display that changed resolution).
public enum GeometryTransition: String, Codable, Sendable {
    /// It jumps, as in phase 0 and 1a.
    case none
    case spring
}

/// How the cursor is drawn.
public struct CursorStyle: Codable, Equatable, Sendable {
    public var show: Bool
    public var style: CursorLook
    /// Multiplies the cursor's real size; with `toma`, 1 is 24 pt of height.
    public var scale: Double
    public var smoothing: CursorSmoothing
    public var hideWhenIdle: Bool
    /// Seconds without moving before it is hidden, with `hideWhenIdle`.
    public var idleDelay: Double
    /// `none`, `ripple-1` or `circle-1`.
    public var clickEffect: String
    /// `none`, `soft-1` or `mechanical-1`.
    public var clickSound: String
    /// 0 to 1.
    public var clickSoundGain: Double
    /// 0 to 1: the shutter, as a fraction of a frame.
    public var motionBlur: Double

    public init(
        show: Bool,
        style: CursorLook,
        scale: Double,
        smoothing: CursorSmoothing,
        hideWhenIdle: Bool,
        idleDelay: Double,
        clickEffect: String,
        clickSound: String,
        clickSoundGain: Double,
        motionBlur: Double
    ) {
        self.show = show
        self.style = style
        self.scale = scale
        self.smoothing = smoothing
        self.hideWhenIdle = hideWhenIdle
        self.idleDelay = idleDelay
        self.clickEffect = clickEffect
        self.clickSound = clickSound
        self.clickSoundGain = clickSoundGain
        self.motionBlur = motionBlur
    }
}

public enum CursorLook: String, Codable, Sendable {
    /// Toma's arrow, drawn in code.
    case toma
    /// The images of the cursor the take recorded.
    case system
}

/// How the drawn cursor follows the recorded one. Encoded as `"off"` or `{"damping":…,"response":…}`.
public enum CursorSmoothing: Codable, Equatable, Sendable {
    /// The recorded positions, interpolated as in phase 0 and 1a.
    case off
    case spring(SpringSpec)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard text == "off" else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Cursor smoothing is \"off\" or a spring, not \"\(text)\".")
            }
            self = .off
        } else {
            self = .spring(try container.decode(SpringSpec.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off: try container.encode("off")
        case let .spring(spec): try container.encode(spec)
        }
    }
}

/// A spring: its damping ratio and its response in seconds.
public struct SpringSpec: Codable, Equatable, Sendable {
    public var damping: Double
    public var response: Double

    public init(damping: Double, response: Double) {
        self.damping = damping
        self.response = response
    }
}

/// The zoom: the blocks, the settings of the automatic ones and the spring of the camera that follows them.
public struct ZoomPlan: Codable, Equatable, Sendable {
    /// `false` turns every zoom off without deleting the blocks.
    public var show: Bool
    public var auto: AutoZoomSettings
    /// The spring of the zoom camera.
    public var spring: SpringSpec
    /// 0 to 1: the shutter, as a fraction of a frame.
    public var motionBlur: Double
    public var regions: [ZoomRegion]
    /// Source ranges where the user deleted an automatic zoom: the planner does not put back one that overlaps
    /// one of them by half or more.
    public var suppressed: [SourceRange]

    public init(
        show: Bool, auto: AutoZoomSettings, spring: SpringSpec, motionBlur: Double, regions: [ZoomRegion], suppressed: [SourceRange]
    ) {
        self.show = show
        self.auto = auto
        self.spring = spring
        self.motionBlur = motionBlur
        self.regions = regions
        self.suppressed = suppressed
    }
}

/// The settings of the automatic zoom's planner.
public struct AutoZoomSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var triggers: ZoomTriggers
    public var holdWhileTyping: Bool
    /// How far it zooms: 1.25 to 4.
    public var depth: Double
    /// Seconds between clicks that still group them into one block.
    public var groupGap: Double
    /// Seconds before the first click a block starts.
    public var leadIn: Double
    /// Seconds after the last click a block ends.
    public var leadOut: Double
    /// Whether the zoom follows the cursor inside a block.
    public var follow: Bool
    /// The planner, with its version (`autoZoom-1`).
    public var planner: String

    public init(
        enabled: Bool,
        triggers: ZoomTriggers,
        holdWhileTyping: Bool,
        depth: Double,
        groupGap: Double,
        leadIn: Double,
        leadOut: Double,
        follow: Bool,
        planner: String
    ) {
        self.enabled = enabled
        self.triggers = triggers
        self.holdWhileTyping = holdWhileTyping
        self.depth = depth
        self.groupGap = groupGap
        self.leadIn = leadIn
        self.leadOut = leadOut
        self.follow = follow
        self.planner = planner
    }
}

public enum ZoomTriggers: String, Codable, Sendable {
    case clicks, clicksAndPauses
}

/// One zoom block over the source times `[start, end)` of `take`.
public struct ZoomRegion: Codable, Equatable, Sendable {
    /// `z-` and 8 hex; for an automatic one, from a hash of its planner, take, start and end.
    public var id: String
    public var take: String
    public var start: HostTime
    /// Excluded.
    public var end: HostTime
    public var origin: Origin
    /// How far it zooms; an automatic one without it uses `AutoZoomSettings.depth`.
    public var depth: Double?
    public var focus: ZoomFocus
    /// Whether it cuts in and out instead of moving with the spring.
    public var instant: Bool

    public init(
        id: String, take: String, start: HostTime, end: HostTime, origin: Origin, depth: Double? = nil, focus: ZoomFocus, instant: Bool
    ) {
        self.id = id
        self.take = take
        self.start = start
        self.end = end
        self.origin = origin
        self.depth = depth
        self.focus = focus
        self.instant = instant
    }
}

/// Where a zoom looks. Encoded flat with its `type`: `{"type":"follow"}` or `{"type":"fixed","x":…,"y":…}`.
public enum ZoomFocus: Codable, Equatable, Sendable {
    /// At the cursor.
    case follow
    /// At a point, in fractions of what is shown of the screen.
    case fixed(x: Double, y: Double)

    private enum CodingKeys: String, CodingKey {
        case type, x, y
    }

    private enum Kind: String, Codable {
        case follow, fixed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .follow:
            self = .follow
        case .fixed:
            self = .fixed(x: try container.decode(Double.self, forKey: .x), y: try container.decode(Double.self, forKey: .y))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .follow:
            try container.encode(Kind.follow, forKey: .type)
        case let .fixed(x, y):
            try container.encode(Kind.fixed, forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        }
    }
}

/// The source times `[start, end)` of `take`.
public struct SourceRange: Codable, Equatable, Sendable {
    public var take: String
    public var start: HostTime
    /// Excluded.
    public var end: HostTime

    public init(take: String, start: HostTime, end: HostTime) {
        self.take = take
        self.start = start
        self.end = end
    }
}

/// The camera: how it looks at the start of each take, and from each change on.
public struct CameraPlan: Codable, Equatable, Sendable {
    public var show: Bool
    /// By take ID. In the document, `size` goes from 0.10 to 0.45.
    public var initial: [String: CameraStyle]
    public var changes: [CameraChange]

    public init(show: Bool, initial: [String: CameraStyle], changes: [CameraChange]) {
        self.show = show
        self.initial = initial
        self.changes = changes
    }
}

/// From source time `t` of `take` on, the camera looks like `style`.
public struct CameraChange: Codable, Equatable, Sendable {
    /// `k-` and 8 hex.
    public var id: String
    public var take: String
    public var t: HostTime
    public var style: CameraStyle
    public var origin: CameraOrigin

    public init(id: String, take: String, t: HostTime, style: CameraStyle, origin: CameraOrigin) {
        self.id = id
        self.take = take
        self.t = t
        self.style = style
        self.origin = origin
    }
}

/// Who made a camera change: the take, as the user changed the bubble while recording, or the user in the editor.
public enum CameraOrigin: String, Codable, Sendable {
    case recorded, user
}

/// The sound: the gain of each audio track and whether the mix goes through the limiter.
public struct AudioPlan: Codable, Equatable, Sendable {
    public var limiter: Bool
    /// By `key(take:track:)`.
    public var tracks: [String: TrackGain]

    public init(limiter: Bool, tracks: [String: TrackGain]) {
        self.limiter = limiter
        self.tracks = tracks
    }

    /// The key of a track in `tracks`: `<take>/<track>`, for example `take-001/mic`.
    public static func key(take: String, track: String) -> String {
        "\(take)/\(track)"
    }
}

public struct TrackGain: Codable, Equatable, Sendable {
    /// 0 to 2.
    public var gain: Double
    public var muted: Bool

    public init(gain: Double, muted: Bool) {
        self.gain = gain
        self.muted = muted
    }
}
