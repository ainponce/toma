// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import ProjectFormat
import SwiftUI

/// The words of the layouts (design §5.1 and §12): «disposición» in the interface.
enum LayoutNames {
    static func name(_ kind: LayoutKind) -> String {
        switch kind {
        case .bubble: String(localized: "Bubble")
        case .screenOnly: String(localized: "Screen Only")
        case .split: String(localized: "Split Screen")
        case .cameraOnly: String(localized: "Camera Only")
        case .cameraFull: String(localized: "Full-Screen Camera")
        }
    }

    /// The five, in the order of the tiles.
    static let order: [LayoutKind] = [.bubble, .screenOnly, .split, .cameraOnly, .cameraFull]
}

/// The five tiles of Disposición (design §5.6), a group of options: each one is drawn with the geometry the render gives
/// the layout (`CameraLayoutGeometry.geometry`) in the project's format, so it looks like what it will do. Moving between
/// them changes the chosen one with `Motion.selector`, and with "Reduce motion", a fade. VoiceOver reads "Layout, Bubble, 1
/// of 5".
struct LayoutTiles: View {
    /// The project's output, in pixels (only its proportions count).
    let output: SIMD2<Double>
    let padding: Double
    let cornerRadius: Double
    let selected: LayoutKind
    /// The split the Split tile shows: the one being edited, if there is one.
    let split: SplitLayout?
    let choose: (LayoutKind) -> Void

    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(LayoutNames.order.enumerated()), id: \.element) { index, kind in
                tile(kind, index: index)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tile(_ kind: LayoutKind, index: Int) -> some View {
        let name = LayoutNames.name(kind)
        let isSelected = kind == selected
        return Button {
            withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) { choose(kind) }
        } label: {
            VStack(spacing: 4) {
                LayoutThumbnail(kind: kind, output: output, padding: padding, cornerRadius: cornerRadius, split: split)
                    .aspectRatio(output.x / output.y, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    }
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .matchedGeometryEffect(id: "ring", in: ring)
                        }
                    }
                Text(verbatim: name)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    // "Cámara a pantalla completa" takes four lines under its tile: none is cut.
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(Text(verbatim: name))
        .accessibilityLabel(
            Text(verbatim: String(format: String(localized: "Layout, %1$@, %2$d of %3$d"), name, index + 1, LayoutNames.order.count)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One layout drawn small: the stage's background, the screen's card in grey and the camera's in the accent colour, at the
/// geometry of `CameraLayoutGeometry` for a 16:9 screen and a medium bubble at the bottom right.
private struct LayoutThumbnail: View {
    let kind: LayoutKind
    let output: SIMD2<Double>
    let padding: Double
    let cornerRadius: Double
    let split: SplitLayout?

    var body: some View {
        Canvas { context, size in
            let scale = size.width / output.x
            func draw(_ rect: Rect, radius: Double, opacity: Double, color: Color) {
                guard opacity > 0, rect.width > 0, rect.height > 0 else { return }
                let box = CGRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
                let path = Path(roundedRect: box, cornerRadius: min(radius * scale, min(box.width, box.height) / 2))
                context.fill(path, with: .color(color.opacity(0.55 * opacity)))
            }
            let screen = StageLayout.screenRect(contentAspect: 16.0 / 9, padding: padding, outputSize: output)
            let bubble = CameraStyle.default.frame(in: screen)
            let geometry = CameraLayoutGeometry.geometry(
                kind: kind, split: split ?? SplitLayout(side: .end), bubble: bubble, output: output, padding: padding,
                cornerRadius: cornerRadius, screenAspect: 16.0 / 9)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.primary.opacity(0.08)))
            draw(geometry.screen.rect, radius: geometry.screen.cornerRadius, opacity: geometry.screen.opacity, color: .secondary)
            draw(geometry.camera.rect, radius: geometry.camera.cornerRadius, opacity: geometry.camera.opacity, color: .accentColor)
        }
        .accessibilityHidden(true)
    }
}
