// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import SwiftUI

/// The safe-zone guide over the preview (`safeZones-1`, phase 2 design §6.6): the strips where the apps of vertical video
/// put their own interface (top, bottom and right) dimmed, a dashed edge where each zone ends and the legend. It is drawn
/// by the app over the preview only, never by the render, so the export never has it; it takes no clicks, so the preview
/// keeps playing and pausing under it. "Reduce transparency" dims more evenly, "Reduce motion" shows it without a fade.
struct SafeZonesOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            let size = SIMD2(Double(proxy.size.width), Double(proxy.size.height))
            let zones = SafeZones.rects(in: size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let dim = Color.black.opacity(reduceTransparency ? 0.62 : 0.42)
                    for zone in zones {
                        context.fill(Path(Self.cgRect(zone)), with: .color(dim))
                    }
                    var edges = Path()
                    let top = zones[0], bottom = zones[1], right = zones[2]
                    edges.move(to: CGPoint(x: 0, y: top.height))
                    edges.addLine(to: CGPoint(x: size.x, y: top.height))
                    edges.move(to: CGPoint(x: 0, y: bottom.y))
                    edges.addLine(to: CGPoint(x: size.x, y: bottom.y))
                    edges.move(to: CGPoint(x: right.x, y: right.y))
                    edges.addLine(to: CGPoint(x: right.x, y: right.y + right.height))
                    context.stroke(
                        edges, with: .color(.white.opacity(0.7)),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 4]))
                }
                Label {
                    Text("Safe zone for Reels, TikTok and Shorts")
                } icon: {
                    Image(systemName: "rectangle.dashed")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(reduceTransparency ? 0.8 : 0.5)))
                .frame(maxWidth: max(0, proxy.size.width - 16))
                .frame(width: proxy.size.width, height: CGFloat(zones[0].height), alignment: .center)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Safe zone for Reels, TikTok and Shorts"))
    }

    private static func cgRect(_ rect: Rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
