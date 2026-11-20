// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What the Replay records (fases 4 y 5 design §10.4, plan 5c decision 10): "the sources of the last recording", as a
/// display, never chosen on their own.
public enum ReplaySelection {
    /// The selection of the last recording (`RecorderSettings.selection`) as the Replay records it:
    /// - displays as they were, each one no longer connected replaced by the main one (once);
    /// - an area as it was, or the main display whole if its display is no longer connected;
    /// - a window as the display it is on now (`windowDisplay`), or the main one if it is gone;
    /// - an iPhone or iPad as the main display;
    /// - without a last recording, the main display alone: no camera, microphone nor system audio.
    ///
    /// The microphone, the camera and system audio as they were chosen, each only if `granted` holds its permission (the
    /// Replay never asks for one). The main display is the one with the menu bar (`DisplayInfo.isMain`), or the first
    /// one; without any display the selection has none, which a take cannot record.
    public static func make(
        last: CaptureSelection?, displays: [DisplayInfo], windowDisplay: (UInt32) -> UInt32?, granted: Set<PermissionKind>
    ) -> CaptureSelection {
        let main = (displays.first(where: \.isMain) ?? displays.first).map { [$0.id] } ?? []
        let connected = Set(displays.map(\.id))
        guard let last else {
            return CaptureSelection(mode: .display, displayIDs: main, camera: .off, microphone: .off, systemAudio: .off)
        }
        let camera = granted.contains(.camera) ? last.camera : .off
        let microphone = granted.contains(.microphone) ? last.microphone : .off
        let systemAudio = granted.contains(.systemAudio) ? last.systemAudio : .off
        func display(_ ids: [UInt32]) -> CaptureSelection {
            CaptureSelection(mode: .display, displayIDs: ids, camera: camera, microphone: microphone, systemAudio: systemAudio)
        }

        switch last.mode {
        case .display:
            var ids: [UInt32] = []
            for id in last.displayIDs.flatMap({ connected.contains($0) ? [$0] : main }) where !ids.contains(id) {
                ids.append(id)
            }
            return display(ids.isEmpty ? main : ids)
        case .area:
            guard let area = last.area, connected.contains(area.displayID) else { return display(main) }
            return CaptureSelection(
                mode: .area, displayIDs: last.displayIDs, area: area, camera: camera, microphone: microphone,
                systemAudio: systemAudio)
        case .window:
            guard let window = last.windowID, let id = windowDisplay(window), connected.contains(id) else { return display(main) }
            return display([id])
        case .device:
            return display(main)
        }
    }
}
