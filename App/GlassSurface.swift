// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import SwiftUI

/// The island's outline: square top corners under the notch, all corners round on a pill.
struct IslandOutline: Shape {
    var bottomRadius: Double
    var roundsTopCorners: Bool

    init(_ shape: IslandShape) {
        bottomRadius = shape.bottomRadius
        roundsTopCorners = shape.roundsTopCorners
    }

    func path(in rect: CGRect) -> Path {
        let top = roundsTopCorners ? bottomRadius : 0
        // Circular corners, so the 9-part mask of macOS 15 is the same outline as the content's clip.
        return UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius, topTrailingRadius: top,
            style: .circular
        ).path(in: rect)
    }
}

extension View {
    /// The island's surface behind this view, which is cut to `shape`: Liquid Glass in macOS 26 (one glass
    /// with one stable ID: the window's frame changes its shape, so SwiftUI never sees a new glass); in
    /// macOS 15, the HUD material with a light 1 pt border; solid black at 92 % with "Reduce transparency".
    /// `black` makes all of it black (at rest under the notch); `topBand` is the height of the black band
    /// at the top that blends into the notch (0 on a pill).
    func islandGlass(_ shape: IslandOutline, black: Bool, topBand: Double, reduceTransparency: Bool) -> some View {
        modifier(IslandGlass(shape: shape, black: black, topBand: topBand, reduceTransparency: reduceTransparency))
    }
}

private struct IslandGlass: ViewModifier {
    static let glassID = "island"

    let shape: IslandOutline
    let black: Bool
    let topBand: Double
    let reduceTransparency: Bool
    @Namespace private var namespace
    @Environment(\.islandReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        let tinted = content.background(alignment: .top) { tint }
        if reduceTransparency {
            tinted.background(Color.black.opacity(0.92)).clipShape(shape)
        } else if #available(macOS 26, *) {
            GlassEffectContainer {
                tinted
                    .glassEffect(.regular.tint(Color.black.opacity(0.35)), in: shape)
                    .glassEffectID(Self.glassID, in: namespace)
            }
            .clipShape(shape)
        } else {
            tinted
                .background { HUDMaterial(shape: shape) }
                .clipShape(shape)
        }
    }

    /// Over the material: the border (macOS 15 and solid), then the black that blends into the notch,
    /// which also hides the border along it.
    private var tint: some View {
        ZStack(alignment: .top) {
            if !usesLiquidGlass {
                // Half of the stroke is cut off by the clip: 1 pt inside the outline.
                shape.stroke(Color.white.opacity(0.18), lineWidth: 2)
            }
            if topBand > 0 {
                VStack(spacing: 0) {
                    Color.black.frame(height: topBand)
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 46)
                    Spacer(minLength: 0)
                }
            }
            Color.black.opacity(black ? 1 : 0)
        }
        // The prototype's fade between black and glass; the design's 200 ms one with "Reduce motion".
        .animation(.easeInOut(duration: reduceMotion ? Motion.reducedMotionFade.timeInterval : 0.32), value: black)
    }

    private var usesLiquidGlass: Bool {
        guard !reduceTransparency else { return false }
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// The macOS 15 material: blends what is behind the window, which SwiftUI's clip does not reach, so it
/// is cut with a 9-part mask image made again whenever the radius changes.
private struct HUDMaterial: NSViewRepresentable {
    let shape: IslandOutline

    final class Coordinator {
        var outline: (radius: Double, roundsTopCorners: Bool)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let coordinator = context.coordinator
        if let outline = coordinator.outline, outline.radius == shape.bottomRadius, outline.roundsTopCorners == shape.roundsTopCorners {
            return
        }
        coordinator.outline = (shape.bottomRadius, shape.roundsTopCorners)
        view.maskImage = Self.mask(shape)
    }

    /// The four corners and a stretchable middle of one point.
    private static func mask(_ shape: IslandOutline) -> NSImage {
        let radius = max(0, shape.bottomRadius)
        let top = shape.roundsTopCorners ? radius : 0
        let image = NSImage(size: NSSize(width: 2 * radius + 1, height: top + radius + 1), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(shape.path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: top, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
