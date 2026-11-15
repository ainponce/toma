// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat
import SwiftUI

/// A screen of the on-screen selection, as its view sees it.
struct OverlayScreen: Equatable {
    let displayID: UInt32
    /// Its frame in global points (y down), the origin of the view's coordinates.
    let frame: Rect
    /// Where the area bar's top goes, from the screen's top: under the choosing island and the capsule that may
    /// hang from it.
    let barTop: Double
}

/// Drawing the area on one screen (Area mode's "Draw on Screen" / "Adjust Area", the prototype's): outside the
/// area the screen is dimmed; a drag there draws a new area in the proportion chosen, with its size live above
/// it; a drag inside moves it, and its corner changes its size. The grid of thirds is over it. On the area's
/// screen (or the one choosing began on) the bar: the proportions, the grid and "Save Area". Every change of the
/// area follows the pointer at once; only a change of proportion moves with the selector spring.
struct AreaSelectionView: View {
    @Bindable var panel: OpenPanelModel
    let screen: OverlayScreen
    let showsBar: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    /// The area as it was when moving it or changing its size began.
    @State private var dragStart: AreaChoice?

    private static let space = "screen"

    var body: some View {
        let area = panel.selection.area.flatMap { $0.displayID == screen.displayID ? $0 : nil }
        ZStack(alignment: .topLeading) {
            Shade(hole: area.map(local))
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .gesture(draw)
                .pointerStyle(.rectSelection)
            if let area {
                frame(of: area)
            }
            if showsBar {
                AreaBar(panel: panel, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
                    .frame(maxWidth: .infinity)
                    .padding(.top, screen.barTop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    // MARK: - The area

    private func frame(of area: AreaChoice) -> some View {
        let rect = local(area)
        return ZStack {
            if panel.showsGrid {
                ThirdsGrid().stroke(Color.white.opacity(0.4), lineWidth: 1)
            }
            RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white, lineWidth: 2)
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .gesture(move)
        .pointerStyle(.grabIdle)
        .overlay(alignment: .topLeading) {
            // Above the area, or inside it at the top of the screen.
            let inside = rect.minY < 34
            sizeTag(of: area)
                .offset(x: inside ? 8 : 0, y: inside ? 8 : -32)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            // Its center 1 pt outside the corner, as the prototype's.
            CornerHandle()
                .offset(x: CornerHandle.side / 2 + 1, y: CornerHandle.side / 2 + 1)
                .gesture(resize)
                .pointerStyle(.frameResize(position: .bottomTrailing))
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    /// "1280 × 720", and the proportion when one is chosen.
    private func sizeTag(of area: AreaChoice) -> some View {
        let size = panel.pixelSize(of: area)
        let text = panel.aspectLock == .free ? size : "\(size) · \(panel.aspectLock.label)"
        return Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .fixedSize()
            .islandGlass(
                IslandOutline(IslandShape(width: 0, height: 24, bottomRadius: 12, roundsTopCorners: true)), black: false, topBand: 0,
                reduceTransparency: reduceTransparency)
    }

    // MARK: - Gestures

    /// A drag on the dimmed screen draws a new area from where it began (a click alone draws nothing).
    private var draw: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                panel.drawArea(from: global(value.startLocation), to: global(value.location), on: screen.displayID)
            }
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let start = dragStart ?? panel.selection.area else { return }
                dragStart = start
                panel.moveArea(start, by: value.translation)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let start = dragStart ?? panel.selection.area else { return }
                dragStart = start
                panel.resizeArea(start, by: value.translation)
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: - Coordinates

    private func local(_ area: AreaChoice) -> CGRect {
        CGRect(x: area.rect.x - screen.frame.x, y: area.rect.y - screen.frame.y, width: area.rect.width, height: area.rect.height)
    }

    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: Double(point.x) + screen.frame.x, y: Double(point.y) + screen.frame.y)
    }
}

/// The proportions, the grid and "Save Area", in a glass capsule.
private struct AreaBar: View {
    @Bindable var panel: OpenPanelModel
    let reduceMotion: Bool
    let reduceTransparency: Bool

    private static let height = 42.0

    var body: some View {
        HStack(spacing: 8) {
            GlassSegmented(
                items: AspectLock.allCases.map { .init(value: $0, title: Text(verbatim: $0.label)) },
                selection: Binding(
                    get: { panel.aspectLock },
                    set: { lock in
                        withAnimation(.island(Motion.selector, reduceMotion: reduceMotion)) { panel.setAspectLock(lock) }
                    }),
                compact: true)
            Button { panel.showsGrid.toggle() } label: {
                Label("Grid", systemImage: "grid")
            }
            .buttonStyle(GlassButtonStyle(compact: true, isOn: panel.showsGrid))
            Button { panel.saveArea() } label: {
                Label("Save Area", systemImage: "bookmark")
            }
            .buttonStyle(GlassButtonStyle(compact: true))
            .disabled(panel.selection.area == nil)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .fixedSize()
        .islandGlass(
            IslandOutline(IslandShape(width: 0, height: Self.height, bottomRadius: Self.height / 2, roundsTopCorners: true)),
            black: false, topBand: 0, reduceTransparency: reduceTransparency)
    }
}

/// The whole view, less the hole (with an even-odd fill).
private struct Shade: Shape {
    var hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole { path.addRect(hole) }
        return path
    }
}

/// Two lines across and two down, at the thirds.
private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for third in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: rect.minX + rect.width * third, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * third, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * third))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * third))
        }
        return path
    }
}

/// The corner that changes the area's size: a small white square, with room around it to grab it.
private struct CornerHandle: View {
    /// What can be grabbed.
    static let side = 30.0

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .frame(width: Self.side, height: Self.side)
            .contentShape(Rectangle())
    }
}
