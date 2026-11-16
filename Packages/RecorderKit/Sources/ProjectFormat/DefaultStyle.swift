// SPDX-License-Identifier: GPL-3.0-or-later

/// The look a new project starts with (design §5.4): the stage, the whole cursor and the zoom's settings. Not the
/// camera, which comes from the take, nor the aspect.
public struct DefaultStyle: Codable, Equatable, Sendable {
    public var style: StageStyle
    public var cursor: CursorStyle
    public var zoomShow: Bool
    public var zoomAuto: AutoZoomSettings
    public var zoomSpring: SpringSpec
    public var zoomMotionBlur: Double

    public init(
        style: StageStyle, cursor: CursorStyle, zoomShow: Bool, zoomAuto: AutoZoomSettings, zoomSpring: SpringSpec, zoomMotionBlur: Double
    ) {
        self.style = style
        self.cursor = cursor
        self.zoomShow = zoomShow
        self.zoomAuto = zoomAuto
        self.zoomSpring = zoomSpring
        self.zoomMotionBlur = zoomMotionBlur
    }

    /// Toma's style, the "New" column of design §5.4: the Aurora wallpaper, the screen padded and rounded as in
    /// phase 0 with a shadow, the recorded cursor at 150 % with Medium smoothing, hidden when idle, with ripples and
    /// motion blur, and the automatic zoom on clicks.
    public static let toma = DefaultStyle(
        style: StageStyle(
            background: .wallpaper("aurora-1"), backgroundBlur: 0, padding: 0.08, cornerRadius: 0.012, shadow: 0.6, frame: .none,
            screenSampling: .mipmapped, geometryTransition: .spring),
        cursor: CursorStyle(
            show: true, style: .system, scale: 1.5, smoothing: .spring(SpringSpec(damping: 1, response: 0.16)), hideWhenIdle: true,
            idleDelay: 2, clickEffect: "ripple-1", clickSound: "none", clickSoundGain: 0.5, motionBlur: 0.5),
        zoomShow: true,
        zoomAuto: AutoZoomSettings(
            enabled: true, triggers: .clicks, holdWhileTyping: true, depth: 2.0, groupGap: 2.5, leadIn: 0.5, leadOut: 1.0, follow: true,
            planner: "autoZoom-1"),
        zoomSpring: SpringSpec(damping: 1.0, response: 0.70),
        zoomMotionBlur: 0.5)
}
