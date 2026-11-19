// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppSupport
import Observation
import Recording
import SwiftUI

// iPhone mode (design §7.6): the iPhones and iPads connected by cable, one chosen with a click, the empty state that
// says how to connect one, and the row that asks for the camera permission recording one needs.

/// The iPhones and iPads connected by cable, as iPhone mode lists them. Nothing until the mode first opens: then the
/// process is let see them (`ExternalDeviceCatalog.allowScreenCaptureDevices()`, off the main thread, since
/// CoreMediaIO may take a while the first time) and they are listed off the main thread, and again whenever a
/// capture device is connected or disconnected (they show up a moment after they are allowed). One for the process,
/// as the setting is.
@MainActor @Observable
final class ExternalDeviceList {
    static let shared = ExternalDeviceList()

    /// In the system's order.
    private(set) var devices: [ExternalDeviceInfo] = []

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isAllowed = false
    /// Only the newest listing is kept.
    @ObservationIgnored private var generation = 0

    private init() {}

    /// iPhone mode shows: the first time, screen devices are allowed; then they are listed.
    func open() async {
        #if DEBUG
        if isShowcase { return }
        #endif
        if observers.isEmpty {
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                observers.append(token)
            }
        }
        // Never the synchronous one here: it waits for CoreMediaIO on the main thread.
        if !isAllowed { isAllowed = await ExternalDeviceCatalog.allowScreenCaptureDevices() }
        refresh()
    }

    private func refresh() {
        generation += 1
        let generation = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let devices = ExternalDeviceCatalog.devices()
            await self?.update(devices, generation: generation)
        }
    }

    private func update(_ listed: [ExternalDeviceInfo], generation: Int) {
        #if DEBUG
        if isShowcase { return }
        #endif
        guard generation == self.generation, listed != devices else { return }
        devices = listed
    }

    #if DEBUG
    @ObservationIgnored private var isShowcase = false
    /// `-TomaShowcase island device-camera`: the camera row as if the permission were not given.
    private(set) var showcaseCamera: PermissionAction?

    /// `-TomaShowcase island device…`: these devices, whatever is connected.
    func showcase(_ devices: [ExternalDeviceInfo], camera: PermissionAction? = nil) {
        isShowcase = true
        self.devices = devices
        showcaseCamera = camera
    }
    #endif
}

extension OpenPanelModel {
    /// The iPhones and iPads iPhone mode lists.
    var externalDevices: ExternalDeviceList { .shared }

    /// A device's row was clicked.
    func choose(device: ExternalDeviceInfo) {
        selection.deviceUniqueID = device.uniqueID
    }

    /// The devices listed changed: the chosen one while it is connected, or the only one connected
    /// (`ExternalDeviceChoice.reconciled`).
    func reconcileDevice() {
        let chosen = ExternalDeviceChoice.reconciled(selection.deviceUniqueID, connected: externalDevices.devices)
        if chosen != selection.deviceUniqueID { selection.deviceUniqueID = chosen }
    }

    /// In iPhone mode, Record needs the chosen device connected (`ExternalDeviceChoice.problem`).
    var deviceProblem: TakePlanError? {
        guard selection.mode == .device else { return nil }
        return ExternalDeviceChoice.problem(chosen: selection.deviceUniqueID, connected: externalDevices.devices)
    }

    /// What the camera row offers: recording an iPhone or iPad needs the camera permission (not the Mac's camera
    /// itself). `nil` once it is given.
    var deviceCameraAction: PermissionAction? {
        #if DEBUG
        if let action = externalDevices.showcaseCamera { return action }
        #endif
        return PermissionAction(for: camera.permission)
    }

    /// The camera row's button: the system's prompt the first time (the island makes room for it), System Settings
    /// once it was refused.
    func giveDeviceCameraPermission() {
        switch deviceCameraAction {
        case .prompt: Task { _ = await camera.requestAccess() }
        case .openSettings: camera.openSettings()
        case nil: break
        }
    }
}

/// iPhone mode's column: the devices connected, each a row chosen with a click, that materialize as they are
/// plugged in; with none, how to connect one; and while the camera permission is not given, a row that asks for it.
struct DeviceChoiceColumn: View {
    @Bindable var panel: OpenPanelModel
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let devices = panel.externalDevices.devices
        VStack(alignment: .leading, spacing: Column<EmptyView>.spacing) {
            ZStack(alignment: .top) {
                if devices.isEmpty {
                    // Smaller when the camera row leaves less room under it.
                    ViewThatFits(in: .vertical) {
                        DeviceEmptyState(isCompact: false)
                        DeviceEmptyState(isCompact: true)
                    }
                    .transition(reduceMotion ? .islandFade : .islandContent)
                } else {
                    ViewThatFits(in: .vertical) {
                        rows(devices)
                        ScrollView { rows(devices) }.scrollIndicators(.automatic)
                    }
                    .transition(reduceMotion ? .islandFade : .islandContent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let action = panel.deviceCameraAction {
                DeviceCameraRow(action: action) { panel.giveDeviceCameraPermission() }
                    .transition(reduceMotion ? .islandFade : .islandContent)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.island(Motion.islandExpand, reduceMotion: reduceMotion), value: devices)
        .animation(.island(Motion.islandExpand, reduceMotion: reduceMotion), value: panel.deviceCameraAction)
        .onChange(of: devices, initial: true) { panel.reconcileDevice() }
        // Each time the mode shows: the first time it lets the process see the devices.
        .task {
            panel.camera.refreshPermission()
            await panel.externalDevices.open()
        }
    }

    private func rows(_ devices: [ExternalDeviceInfo]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(devices, id: \.uniqueID) { device in
                ChoiceRow(
                    title: Text(verbatim: device.name),
                    subtitle: Text("Connected by cable", comment: "An iPhone or iPad iPhone mode lists: it is plugged into the Mac"),
                    icon: .symbol(ExternalDeviceKind(device).symbol),
                    isChosen: panel.selection.deviceUniqueID == device.uniqueID,
                    choose: { panel.choose(device: device) })
                .transition(reduceMotion ? .islandFade : .islandContent)
            }
        }
    }
}

/// No iPhone or iPad connected: the cable's symbol and how to connect one, in the middle of the column; compact, a
/// smaller symbol closer to the line.
private struct DeviceEmptyState: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 7 : 10) {
            Image(systemName: "cable.connector")
                .font(.system(size: isCompact ? 15 : 18))
                .symbolRenderingMode(.hierarchical)
                .opacity(0.6)
                .frame(width: isCompact ? 34 : 44, height: isCompact ? 34 : 44)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .accessibilityHidden(true)
            Text(
                "Connect the iPhone or iPad with a cable, unlock it and tap Trust.",
                comment: "iPhone mode with no iPhone or iPad connected: how to connect one (Trust is the button the device shows)")
                .font(.system(size: 12))
                .lineSpacing(1)
                .opacity(0.7)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        // In the middle of what the card has under its title, a little above center, as the camera's when it is off.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, isCompact ? 0 : 18)
        .accessibilityElement(children: .combine)
    }
}

/// Recording an iPhone or iPad needs the camera permission: the line that says so, and the button that asks for it
/// (or opens System Settings once it was refused).
private struct DeviceCameraRow: View {
    let action: PermissionAction
    let givePermission: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: NoticePresentation.attention.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(NoticePresentation.attention.tint)
                    .accessibilityHidden(true)
                Text(
                    "Recording an iPhone or iPad needs camera access.",
                    comment: "iPhone mode while Toma may not use the camera: the screen of an iPhone or iPad comes through it")
                    .foregroundStyle(Color(red: 1, green: 0.89, blue: 0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5))
            Button(action: givePermission) { Text("Give Permission…") }
                .buttonStyle(GlassButtonStyle(compact: true))
                .fixedSize()
                .help(action == .openSettings ? String(localized: "Open System Settings") : "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NoticePresentation.attention.tint.opacity(0.16))
        }
        .accessibilityElement(children: .contain)
    }
}
