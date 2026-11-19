// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import SwiftUI

/// System audio's permission (plan decision 7): macOS never says whether it was allowed, so it is "not asked"
/// until it is asked for once, and "asked" after that. It is asked for when system audio is turned on in the open
/// island, never after Record: the system's prompt would be on the screen during the take.
@MainActor @Observable
final class SystemAudioSetting {
    /// As it was last read.
    private(set) var permission: PermissionState

    /// The system's prompt may be about to show (`true`, with the island open) or the request is over (`false`, the
    /// prompt may stay): the island makes room for the prompt.
    @ObservationIgnored var askingChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private var isAsking = false

    init(probe: any PermissionProbe) {
        self.probe = probe
        permission = probe.state(of: .systemAudio)
    }

    /// Reads the permission again.
    func refreshPermission() {
        let state = probe.state(of: .systemAudio)
        if state != permission { permission = state }
    }

    /// Asks the system the first time: a short tap of every app, which makes macOS show its prompt now, with the
    /// island open. Nothing once it was asked.
    func requestIfNeverAsked() {
        refreshPermission()
        guard permission == .notDetermined, !isAsking else { return }
        isAsking = true
        askingChanged(true)
        Task {
            let state = await probe.request(.systemAudio)
            isAsking = false
            if state != permission { permission = state }
            askingChanged(false)
        }
    }
}

extension OpenPanelModel {
    /// No, All or By App; turning it on asks for the permission the first time.
    func setSystemAudio(_ choice: SystemAudioChoice) {
        selection.systemAudio = choice
        if choice != .off { systemAudio.requestIfNeverAsked() }
    }

    /// By App: `bundleID` is recorded, or no longer.
    func toggle(audioApplication bundleID: String) {
        guard case .applications(var chosen) = selection.systemAudio else { return }
        if let index = chosen.firstIndex(of: bundleID) { chosen.remove(at: index) } else { chosen.append(bundleID) }
        selection.systemAudio = .applications(chosen)
    }

    /// The apps chosen By App, open or not.
    var chosenAudioApplications: [AudioApplication] {
        guard case .applications(let chosen) = selection.systemAudio else { return [] }
        return chosen.map(audioApplications.application)
    }
}

/// System audio, without Toma or notifications: No · All · By App. By App, the chosen apps' icons and "Choose
/// Apps…", a menu of the open apps (the ones playing audio first), each with its icon and a check once chosen.
struct SystemAudioPicker: View {
    @Bindable var panel: OpenPanelModel
    @Environment(\.islandReduceMotion) private var reduceMotion

    private enum Tab: Hashable {
        case none, all, byApp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlassSegmented(
                items: [
                    .init(value: Tab.none, title: Text("None", comment: "System audio: record none; the countdown: none")),
                    .init(value: .all, title: Text("All", comment: "System audio: record all of it")),
                    .init(value: .byApp, title: Text("By App")),
                ],
                selection: Binding(
                    get: {
                        switch panel.selection.systemAudio {
                        case .off: Tab.none
                        case .all: .all
                        case .applications: .byApp
                        }
                    },
                    set: { tab in
                        switch tab {
                        case .none: panel.setSystemAudio(.off)
                        case .all: panel.setSystemAudio(.all)
                        case .byApp:
                            if case .applications = panel.selection.systemAudio { return }
                            panel.setSystemAudio(.applications([]))
                        }
                    }),
                compact: true, fills: true)
            if case .applications = panel.selection.systemAudio {
                HStack(spacing: 6) {
                    chosenIcons
                    appsMenu
                }
                .transition(.opacity)
            }
        }
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: isByApp)
    }

    private var isByApp: Bool {
        if case .applications = panel.selection.systemAudio { true } else { false }
    }

    /// Overlapping a little, as a stack.
    @ViewBuilder
    private var chosenIcons: some View {
        let chosen = panel.chosenAudioApplications
        if !chosen.isEmpty {
            HStack(spacing: -5) {
                ForEach(chosen.prefix(5)) { app in
                    AppIcon(image: app.icon, side: 18).help(app.name)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: ListFormatter.localizedString(byJoining: chosen.map(\.name))))
        }
    }

    /// A menu, as the microphone's: it opens without activating the app.
    private var appsMenu: some View {
        let applications = panel.audioApplications.applications
        let chosen = Set(panel.chosenAudioApplications.map(\.id))
        let playing = applications.filter(\.isPlayingAudio)
        let others = applications.filter { !$0.isPlayingAudio }
        return Menu {
            ForEach(playing) { app in item(app, isOn: chosen.contains(app.id)) }
            if !playing.isEmpty, !others.isEmpty { Divider() }
            ForEach(others) { app in item(app, isOn: chosen.contains(app.id)) }
            // Chosen before, and not open now: they can still be left out.
            let closed = panel.chosenAudioApplications.filter { app in !applications.contains { $0.id == app.id } }
            if !closed.isEmpty {
                Divider()
                ForEach(closed) { app in item(app, isOn: true) }
            }
        } label: {
            Text("Choose Apps…")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.10)).overlay(Capsule().stroke(Color.white.opacity(0.15))))
        .onAppear { panel.audioApplications.refresh() }
    }

    private func item(_ app: AudioApplication, isOn: Bool) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in panel.toggle(audioApplication: app.id) })) {
            Label {
                Text(verbatim: app.name)
            } icon: {
                if let icon = app.icon.map(Self.menuSized) { Image(nsImage: icon) }
            }
        }
    }

    /// Menus draw an image at its own size: an app's icon at the size of the menu's text.
    private static func menuSized(_ icon: NSImage) -> NSImage {
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }
}

/// An app's icon at `side` points, or an app symbol when it has none.
private struct AppIcon: View {
    let image: NSImage?
    let side: Double

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().frame(width: side, height: side)
        } else {
            Image(systemName: "app.dashed").symbolRenderingMode(.hierarchical).frame(width: side, height: side)
        }
    }
}
