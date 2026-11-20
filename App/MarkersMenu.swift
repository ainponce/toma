// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import SwiftUI

/// The Markers menu of the editor's bar (phase 3 design §8.3, 3d plan decision 3): each marker the output shows with its
/// output time and its name ("0:12 Intro", "0:40 Unnamed Marker"), a click taking the playhead there; then Add Marker
/// (M), Previous Marker (⌥←) and Next Marker (⌥→); Rename Marker… and Delete Marker, of the marker at the playhead;
/// and Copy Chapters, with a marker with a name. The keys are shown under the commands' names, never as the menu's key
/// equivalents: M and ⌥← are the editor's keys only with the focus on the preview or the timeline (`KeyboardCommands`),
/// never in a field.
struct MarkersMenu: View {
    let model: EditorModel

    var body: some View {
        let markers = model.visibleMarkers
        Menu {
            if markers.isEmpty {
                Text("No Markers", comment: "The Markers menu, while the output shows none")
            }
            ForEach(markers, id: \.id) { marker in
                Button(Self.title(marker)) { model.goTo(marker) }
            }
            Divider()
            Button {
                model.addMarkerAtPlayhead()
            } label: {
                Label {
                    Text("Add Marker")
                    Text(verbatim: "M")
                } icon: {
                    Image(systemName: "flag.fill")
                }
            }
            .disabled(!model.canEdit)
            Button {
                model.goToMarker(forward: false)
            } label: {
                Text("Previous Marker")
                Text(verbatim: "⌥←")
            }
            .disabled(markers.isEmpty || !model.canPlay)
            Button {
                model.goToMarker(forward: true)
            } label: {
                Text("Next Marker")
                Text(verbatim: "⌥→")
            }
            .disabled(markers.isEmpty || !model.canPlay)
            Divider()
            MarkerAtPlayheadItems(model: model)
            Divider()
            Button {
                model.copyChapters()
            } label: {
                Label("Copy Chapters", systemImage: "list.bullet.rectangle")
            }
            .disabled(!markers.contains { !$0.name.isEmpty })
        } label: {
            Label("Markers", systemImage: "bookmark")
        }
        .disabled(model.state != .ready)
        .help(Text("Markers"))
        .accessibilityLabel(Text("Markers"))
    }

    /// "0:12 Intro", "0:40 Unnamed Marker": its output time in whole seconds and its name.
    static func title(_ marker: VisibleMarker) -> String {
        let name = marker.name.isEmpty ? String(localized: "Unnamed Marker") : marker.name
        return Timecode.duration(Double(marker.output) / 1e9) + " " + name
    }
}

/// Rename Marker… and Delete Marker, of the marker at the playhead: a view of their own, so that only they follow the
/// playhead.
private struct MarkerAtPlayheadItems: View {
    let model: EditorModel

    var body: some View {
        let marker = model.markerAtPlayhead
        Button("Rename Marker…") {
            if let marker { model.askMarkerName(marker) }
        }
        .disabled(marker == nil || !model.canEdit)
        Button("Delete Marker") {
            if let marker { model.deleteMarker(marker) }
        }
        .disabled(marker == nil || !model.canEdit)
    }
}
