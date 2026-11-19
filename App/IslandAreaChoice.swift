// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import CoreGraphics
import ProjectFormat
import SwiftUI

// Area mode (notch design §5.2): the area chosen with its size and proportion, "Draw on Screen" / "Adjust Area",
// the saved areas, and the privacy note of plan decision 1.

extension OpenPanelModel {
    /// The areas saved on displays connected now.
    var connectedSavedAreas: [AreaChoice] {
        savedAreas.areas.filter { area in displays.contains { $0.id == area.displayID } }
    }

    /// An area's size in the pixels it records at: its display's pixels per point at Native, one at Points.
    func pixelSize(of area: AreaChoice) -> String {
        let display = displays.first { $0.id == area.displayID }
        let scale = quick.displayScale == .points ? 1 : display?.info.scale ?? 1
        return formattedSize(width: area.rect.width * scale, height: area.rect.height * scale)
    }

    /// The proportion of `area` and the display it is on, as "16:9 · Built-in Retina Display".
    func details(of area: AreaChoice) -> String {
        let proportion = AspectLock.matching(area.rect).label
        guard let name = displays.first(where: { $0.id == area.displayID })?.name, !name.isEmpty else { return proportion }
        return "\(proportion) · \(name)"
    }

    /// A drag from `start` to `current` (global points) on `displayID` draws the area, in the proportion chosen.
    func drawArea(from start: CGPoint, to current: CGPoint, on displayID: UInt32) {
        guard let display = displays.first(where: { $0.id == displayID }) else { return }
        let rect = AreaDrag.rect(from: start, to: current, within: display.info.frame, lock: aspectLock)
        selection.area = AreaChoice(displayID: displayID, rect: rect)
    }

    /// The area as it was when the drag began, moved by the drag.
    func moveArea(_ start: AreaChoice, by offset: CGSize) {
        guard let display = displays.first(where: { $0.id == start.displayID }) else { return }
        let rect = AreaDrag.moved(start.rect, by: CGVector(dx: offset.width, dy: offset.height), within: display.info.frame)
        selection.area = AreaChoice(displayID: start.displayID, rect: rect)
    }

    /// The area as it was when the drag of its corner began, its corner moved by the drag: its top left stays.
    func resizeArea(_ start: AreaChoice, by offset: CGSize) {
        let corner = CGPoint(x: start.rect.x + start.rect.width + offset.width, y: start.rect.y + start.rect.height + offset.height)
        drawArea(from: CGPoint(x: start.rect.x, y: start.rect.y), to: corner, on: start.displayID)
    }

    /// From now on areas are drawn in `lock`; the area drawn takes it at once, keeping its top left and its width.
    func setAspectLock(_ lock: AspectLock) {
        setAreaSettings(lock: lock)
        guard let area = selection.area else { return }
        resizeArea(area, by: .zero)
    }

    /// "Save Area": the area drawn is the most recent saved one, and the capsule says so.
    func saveArea() {
        guard let area = selection.area else { return }
        var saved = savedAreas
        saved.remember(area)
        setAreaSettings(saved: saved)
        confirm(.areaSaved)
    }
}

extension AspectLock {
    /// "Free", "16:9", "9:16", "1:1", "4:3".
    var label: String {
        switch self {
        case .free: String(localized: "Free", comment: "An area's proportion: none")
        case .wide16x9: "16:9"
        case .tall9x16: "9:16"
        case .square: "1:1"
        case .classic4x3: "4:3"
        }
    }
}

/// Area mode's column: the area chosen, drawing or adjusting it on the screen, the saved areas, and that the
/// whole display is recorded.
struct AreaChoiceColumn: View {
    @Bindable var panel: OpenPanelModel
    let send: (IslandEvent) -> Void
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Column<EmptyView>.spacing) {
            if let area = panel.selection.area {
                ChoiceRow(
                    title: Text(verbatim: panel.pixelSize(of: area)), subtitle: Text(verbatim: panel.details(of: area)),
                    icon: .symbol("viewfinder"), isChosen: true, choose: {})
                .transition(.opacity)
            }
            Button { send(.beganChoosing) } label: {
                if panel.selection.area == nil {
                    Label("Draw on Screen", systemImage: "viewfinder")
                } else {
                    Label("Adjust Area", systemImage: "viewfinder")
                }
            }
            .buttonStyle(GlassButtonStyle())
            let saved = panel.connectedSavedAreas
            if saved.isEmpty {
                Spacer(minLength: 0)
            } else {
                ColumnSection(title: Text("Saved Areas")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(saved.indices, id: \.self) { index in
                                let area = saved[index]
                                ChoiceRow(
                                    title: Text(verbatim: panel.pixelSize(of: area)), subtitle: Text(verbatim: panel.details(of: area)),
                                    icon: .symbol("bookmark"), isChosen: panel.selection.area == area,
                                    choose: { panel.selection.area = area })
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            ColumnNote(
                text: Text("The whole display is recorded: what's outside the area is saved too. The area can be changed later."))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: panel.selection.area == nil)
    }
}
