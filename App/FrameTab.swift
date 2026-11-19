// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import SwiftUI

/// The Frame tab (design §5.4, phase 2 design §6.5 and §6.7): how the screen fills the stage (Fit, or Follow the Cursor
/// where the content is wide enough for the format, `FrameTabRules.reframeOffer`; disabled with the reason where it is not),
/// then the frame around it, five tiles drawn with the render's geometry around the project's content (`FrameTiles`), and
/// the chosen one's options: a device's finish, or the window's appearance, title and buttons. Following the cursor, no
/// frame is drawn: the tab says so and dims the frames, which can still be chosen for when the screen is fitted again.
struct FrameTab: View {
    let model: EditorModel
    let style: StageStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The content's width over height, for the tiles: 16:9 until the editor has read it.
    private var contentAspect: Double {
        model.document.flatMap(model.contentRatio(of:)) ?? 16.0 / 9
    }

    var body: some View {
        let offer = model.document.map(model.reframeOffer(of:)) ?? .unknown
        let drawn = FrameTabRules.frameIsDrawn(style)
        VStack(alignment: .leading, spacing: 20) {
            ScreenFramingSection(reframe: style.reframe, offer: offer) { reframe in
                withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) { model.setReframe(reframe) }
            }
            PanelSection("Frame") {
                if !drawn {
                    PanelNote("With Follow the Cursor, no frame is drawn.", symbol: "info.circle")
                        .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 14) {
                    FrameTiles(current: style.frame, contentAspect: contentAspect, isDimmed: !drawn) { choice in
                        withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) {
                            model.setFrame(choice.frame(from: style.frame))
                        }
                    }
                    options
                }
                .opacity(drawn ? 1 : 0.45)
            }
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: FrameChoice(style.frame))
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: drawn)
    }

    /// The chosen frame's options: a device's finish, or the window's appearance, title and buttons.
    @ViewBuilder
    private var options: some View {
        switch style.frame {
        case .none:
            EmptyView()
        case let .device(device):
            Picker(
                "Finish",
                selection: Binding(
                    get: { device.finish },
                    set: { finish in
                        guard let frame = FrameTabRules.frame(style.frame, finish: finish) else { return }
                        withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) { model.setFrame(frame) }
                    })
            ) {
                Text("finish.dark").tag(FrameAppearance.dark)
                Text("finish.light").tag(FrameAppearance.light)
            }
            .pickerStyle(.segmented)
            .panelTitled("Finish")
            .transition(.opacity)
        case let .macWindow(appearance, title, buttons):
            VStack(alignment: .leading, spacing: 14) {
                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { appearance }, set: { model.setFrame(.macWindow(appearance: $0, title: title, buttons: buttons)) })
                ) {
                    Text("Light").tag(FrameAppearance.light)
                    Text("Dark").tag(FrameAppearance.dark)
                }
                .pickerStyle(.segmented)
                .panelTitled("Appearance")
                TextField(
                    "Title",
                    text: Binding(get: { title }, set: { model.setFrame(.macWindow(appearance: appearance, title: $0, buttons: buttons)) })
                )
                .textFieldStyle(.roundedBorder)
                Toggle(
                    "Window Buttons",
                    isOn: Binding(get: { buttons }, set: { model.setFrame(.macWindow(appearance: appearance, title: title, buttons: $0)) }))
            }
            .transition(.opacity)
        }
    }
}

/// "Screen Framing: Fit / Follow the Cursor" (phase 2 design §6.5). Where it is not offered, the control is disabled and
/// a note under it says why; a document that follows the cursor anyway keeps it usable, to go back to Fit.
private struct ScreenFramingSection: View {
    let reframe: Reframe
    let offer: ReframeOffer
    let set: (Reframe) -> Void

    /// Why Follow the Cursor is not offered, and its symbol; `nil` where it is, or while the content is not known yet.
    private var reason: (text: LocalizedStringKey, symbol: String)? {
        switch offer {
        case .offered, .unknown: nil
        case .notWideEnough: ("The recording isn't wide enough for this format.", "arrow.left.and.right")
        case .noCursor: ("An iPhone or iPad has no cursor to follow.", "cursorarrow.slash")
        }
    }

    var body: some View {
        let enabled = FrameTabRules.reframeIsEnabled(offer: offer, reframe: reframe)
        let reason = reason
        PanelSection("Screen Framing") {
            Picker("Screen Framing", selection: Binding(get: { reframe }, set: set)) {
                Text("reframe.fit").tag(Reframe.fit)
                Text("Follow the Cursor").tag(Reframe.followCursor)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!enabled)
            .help(reason.map { Text($0.text) } ?? Text(verbatim: ""))
            .accessibilityHint(reason.map { Text($0.text) } ?? Text(verbatim: ""))
            if let reason {
                PanelNote(reason.text, symbol: reason.symbol)
                    // Read with the control, by its hint.
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A short note of the panel: a symbol and a line or two of secondary text on a faint plate, never cut.
struct PanelNote: View {
    let text: LocalizedStringKey
    let symbol: String

    init(_ text: LocalizedStringKey, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The tiles

/// The five frames as tiles, none and the window on top and the three devices under them, each drawn as a click on it
/// would leave the project (`FrameChoice.frame(from:)`, its finish included) around the project's content. The chosen
/// one's ring moves by `Motion.selector`; with "Reduce motion", a fade. VoiceOver reads "Frame, iPhone, 3 of 5".
private struct FrameTiles: View {
    let current: WindowFrame
    let contentAspect: Double
    let isDimmed: Bool
    let choose: (FrameChoice) -> Void

    @Namespace private var ring

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                tile(.none)
                tile(.macWindow)
            }
            HStack(alignment: .top, spacing: 8) {
                tile(.iPhone)
                tile(.iPad)
                tile(.macBook)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tile(_ choice: FrameChoice) -> some View {
        let isSelected = FrameChoice(current) == choice
        let index = FrameChoice.allCases.firstIndex(of: choice) ?? 0
        let name = FrameNames.name(choice)
        return Button { choose(choice) } label: {
            VStack(spacing: 5) {
                FrameThumbnail(frame: choice.frame(from: current), contentAspect: contentAspect)
                    .frame(height: 62)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .matchedGeometryEffect(id: "ring", in: ring)
                        }
                    }
                Text(verbatim: name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FrameTileStyle())
        .frame(maxWidth: .infinity)
        .help(Text(verbatim: name))
        .accessibilityLabel(
            Text(verbatim: String(format: String(localized: "Frame, %1$@, %2$d of %3$d"), name, index + 1, FrameChoice.allCases.count)))
        .accessibilityHint(isDimmed ? Text("With Follow the Cursor, no frame is drawn.") : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The names of the frames, as the tiles show them.
enum FrameNames {
    static func name(_ choice: FrameChoice) -> String {
        switch choice {
        case .none: String(localized: "frame.none")
        case .macWindow: String(localized: "macOS Window")
        case .iPhone: String(localized: "iPhone", comment: "The header of the track of an iPhone's sound")
        case .iPad: String(localized: "iPad", comment: "The header of the track of an iPad's sound")
        case .macBook: String(localized: "MacBook", comment: "The Frame tab: a MacBook drawn around the screen")
        }
    }
}

/// A tile's plate: faint, a little stronger while the mouse is over it, and pressed in while clicked.
private struct FrameTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FrameTileBody(configuration: configuration)
    }
}

private struct FrameTileBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .background(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.085 : 0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    }
                    .frame(height: 62)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: hovering)
            .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: configuration.isPressed)
            .onHover { hovering = $0 && isEnabled }
    }
}

/// A frame drawn small around a screen of `contentAspect`: the devices with the render's own geometry
/// (`StageLayout.deviceRects`, `deviceFrame-1`) and colours, the window as a simplified one with its bar and buttons, and
/// the screen as a wash of the accent colour.
private struct FrameThumbnail: View {
    let frame: WindowFrame
    let contentAspect: Double

    /// The space around the frame inside the tile, in points.
    private static let margin = 8.0

    var body: some View {
        Canvas { context, size in
            let output = SIMD2(Double(size.width), Double(size.height))
            guard output.x > 2 * Self.margin, output.y > 2 * Self.margin else { return }
            let padding = Self.margin / output.x
            switch frame {
            case .none:
                let screen = StageLayout.screenRect(contentAspect: contentAspect, padding: padding, outputSize: output)
                drawScreen(screen.cg, radius: min(screen.width, screen.height) * 0.06, in: &context)
            case let .macWindow(appearance, _, buttons):
                drawWindow(appearance: appearance, buttons: buttons, output: output, in: &context)
            case let .device(device):
                guard let rects = StageLayout.deviceRects(
                    contentAspect: contentAspect, padding: padding, outputSize: output, model: device.model)
                else { return }
                drawDevice(rects, device: device, in: &context)
            }
        }
        .accessibilityHidden(true)
    }

    /// The screen: a diagonal wash of the accent colour with a faint sheen at its top.
    private func drawScreen(_ rect: CGRect, radius: Double, in context: inout GraphicsContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = Path(roundedRect: rect, cornerRadius: min(radius, min(rect.width, rect.height) / 2), style: .continuous)
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.5)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.midY)))
    }

    /// A generic macOS window: its bar (light #ECECEC or dark #2B2B2E, `windowFrame`'s colours) over the screen, with the
    /// three buttons, a little taller than the render's so it reads at this size.
    private func drawWindow(appearance: FrameAppearance, buttons: Bool, output: SIMD2<Double>, in context: inout GraphicsContext) {
        let room = output - 2 * Self.margin
        let barShare = 0.16
        // A window `w` wide is `w / a × (1 + barShare)` tall.
        let width = min(room.x, room.y / ((1 / contentAspect) * (1 + barShare)))
        let screenHeight = width / contentAspect, bar = screenHeight * barShare
        let window = CGRect(
            x: (output.x - width) / 2, y: (output.y - screenHeight - bar) / 2, width: width, height: screenHeight + bar)
        let radius = min(window.width, window.height) * 0.07
        let shape = Path(roundedRect: window, cornerRadius: radius, style: .continuous)
        let barColor = appearance == .dark ? Color(hex: 0x2B2B2E) : Color(hex: 0xECECEC)
        context.fill(shape, with: .color(barColor))
        var screenContext = context
        screenContext.clip(to: shape)
        drawScreen(CGRect(x: window.minX, y: window.minY + bar, width: window.width, height: screenHeight), radius: 0, in: &screenContext)
        if buttons {
            let diameter = bar * 0.42
            for (k, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let centre = CGPoint(x: window.minX + bar * (0.6 + 0.66 * Double(k)), y: window.minY + bar / 2)
                let dot = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: dot), with: .color(Color(hex: UInt32(hex))))
            }
        }
        context.stroke(shape, with: .color(Color.primary.opacity(0.2)), lineWidth: 0.5)
    }

    /// A device as `deviceFrame-1` draws it: the body in its band's colour (the MacBook's lid), the black bezel inside
    /// it, the screen, the island or the notch, the iPhone's buttons and the MacBook's base with its groove; a hairline
    /// around the body keeps its edge at this size, on any panel.
    private func drawDevice(_ rects: DeviceRects, device: DeviceFrame, in context: inout GraphicsContext) {
        let dark = device.finish == .dark
        let band: Color, bezel: Color
        switch device.model {
        case .iPhone, .iPad:
            band = Color(hex: dark ? 0x2C2C2E : 0xD9D9DE)
            bezel = .black
        case .macBook:
            band = Color(hex: dark ? 0x2E2F33 : 0xD7D8DC)
            bezel = Color(hex: 0x0A0A0A)
        }
        let outline = Color.primary.opacity(0.22)
        for button in rects.buttons {
            let rect = button.cg
            context.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2), with: .color(band))
        }
        if let base = rects.base?.cg {
            let shape = UnevenRoundedRectangle(
                bottomLeadingRadius: rects.baseFrontRadius, bottomTrailingRadius: rects.baseFrontRadius, style: .continuous
            ).path(in: base)
            context.fill(shape, with: .color(band))
            let groove = CGRect(
                x: base.midX - base.width * DeviceMeasures.macBookGrooveWidth / 2, y: base.minY,
                width: base.width * DeviceMeasures.macBookGrooveWidth, height: base.height * DeviceMeasures.macBookGrooveHeight)
            context.fill(
                UnevenRoundedRectangle(bottomLeadingRadius: groove.height / 2, bottomTrailingRadius: groove.height / 2).path(in: groove),
                with: .color(.black.opacity(1 - DeviceMeasures.macBookGrooveShade)))
            context.stroke(shape, with: .color(outline), lineWidth: 0.5)
        }
        let body = rects.body.cg
        let bodyShape: Path
        let bezelShape: Path
        let inner = body.insetBy(dx: rects.bandWidth, dy: rects.bandWidth)
        if device.model == .macBook {
            let top = rects.bodyCornerRadius, bottom = DeviceMeasures.macBookLidBottomCorners * rects.screen.width
            bodyShape = UnevenRoundedRectangle(
                topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top,
                style: .continuous
            ).path(in: body)
            bezelShape = UnevenRoundedRectangle(
                topLeadingRadius: max(top - rects.bandWidth, 0), bottomLeadingRadius: max(bottom - rects.bandWidth, 0),
                bottomTrailingRadius: max(bottom - rects.bandWidth, 0), topTrailingRadius: max(top - rects.bandWidth, 0),
                style: .continuous
            ).path(in: inner)
        } else {
            bodyShape = Path(roundedRect: body, cornerRadius: rects.bodyCornerRadius, style: .continuous)
            bezelShape = Path(roundedRect: inner, cornerRadius: max(rects.bodyCornerRadius - rects.bandWidth, 0), style: .continuous)
        }
        context.fill(bodyShape, with: .color(band))
        context.fill(bezelShape, with: .color(bezel))
        drawScreen(rects.screen.cg, radius: rects.screenCornerRadius, in: &context)
        if let cutout = rects.cutout?.cg {
            let shape: Path = device.model == .macBook
                ? UnevenRoundedRectangle(bottomLeadingRadius: cutout.height * 0.4, bottomTrailingRadius: cutout.height * 0.4)
                    .path(in: cutout)
                : Path(roundedRect: cutout, cornerRadius: min(cutout.width, cutout.height) / 2)
            context.fill(shape, with: .color(.black))
        }
        context.stroke(bodyShape, with: .color(outline), lineWidth: 0.5)
    }
}

private extension Rect {
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private extension Color {
    /// An opaque sRGB colour of `hex` (`0xRRGGBB`).
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
