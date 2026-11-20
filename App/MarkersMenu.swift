// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import LocalAI
import SwiftUI

/// The Markers menu of the editor's bar (phase 3 design §8.3, 3d plan decision 3): each marker the output shows with its
/// output time and its name ("0:12 Intro", "0:40 Unnamed Marker"), a click taking the playhead there; then Add Marker
/// (M), Previous Marker (⌥←) and Next Marker (⌥→); Rename Marker… and Delete Marker, of the marker at the playhead;
/// Copy Chapters, with a marker with a name; and Propose Chapters… and Copy Description for YouTube (plan 5b decision
/// 12). The keys are shown under the commands' names, never as the menu's key equivalents: M and ⌥← are the editor's
/// keys only with the focus on the preview or the timeline (`KeyboardCommands`), never in a field.
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
            AIMarkerItems(ai: model.ai)
        } label: {
            Label("Markers", systemImage: "bookmark")
        }
        .disabled(model.state != .ready)
        // The language the model is asked to write is the transcript's: read again whether it can as that changes.
        .onChange(of: model.document?.transcript?.language) { model.ai.refreshAvailability() }
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

/// Propose Chapters…, dimmed with the reason as its second line when Apple Intelligence can't write (the pattern of Add
/// Marker and its key), and Copy Description for YouTube, with a summary or a chapter (plan 5b decisions 12 and 14).
/// Whether the model can write is read again as the menu opens.
private struct AIMarkerItems: View {
    let ai: EditorAI

    var body: some View {
        Button {
            ai.proposeChapters()
        } label: {
            Label {
                Text("Propose Chapters…")
                if case .unavailable(let reason) = ai.availability {
                    Text(verbatim: EditorAI.text(reason))
                }
            } icon: {
                Image(systemName: "sparkles")
            }
        }
        .disabled(!ai.canPropose)
        .onAppear { ai.refreshAvailability() }
        Button {
            ai.copyYouTubeDescription()
        } label: {
            Label("Copy Description for YouTube", systemImage: "doc.on.clipboard")
        }
        .disabled(!ai.canCopyYouTubeDescription)
    }
}
