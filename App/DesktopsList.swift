// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import SwiftUI

/// The desktops of the island's display while a list shows them (notch design §5.5): read when one appears
/// and whenever the desktop in front changes, jumped to with ⌃← ⌃→, and why a jump posted nothing. It also
/// tells the island when losing the keyboard is the desktop changing (`SpaceSwitchGrace`), so a jump from
/// the open island leaves it open.
@MainActor @Observable
final class DesktopsModel {
    /// Why the last jump posted nothing; the island says how to fix it until the next jump or the list goes.
    enum Problem: Equatable {
        case needsAccessibility, shortcutsOff
    }

    /// The desktops of the island's display, with the one in front; `nil` without a list (no reader, a
    /// result of another shape, no desktop in front), and the island shows ← → and Mission Control instead.
    private(set) var spaces: [DesktopSpace]?
    private(set) var problem: Problem?
    /// The display the island is on.
    var displayID: UInt32 {
        didSet { if displayID != oldValue, viewers > 0 { reload() } }
    }

    /// What the desktops do to the island: `systemUIOpened`.
    @ObservationIgnored var send: (IslandEvent) -> Void = { _ in }
    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private let jumper = SpaceJumper.live()
    /// How many lists show now: two overlap while the island's content changes.
    @ObservationIgnored private var viewers = 0
    /// For the life of the app.
    @ObservationIgnored private var spaceChange: (any NSObjectProtocol)?
    /// A jump is posting its presses: another one would start from a desktop that is no longer in front.
    @ObservationIgnored private var isJumping = false
    @ObservationIgnored private var switchGrace = SpaceSwitchGrace()
    @ObservationIgnored private let origin = ContinuousClock.now

    init(displayID: UInt32, probe: any PermissionProbe) {
        self.displayID = displayID
        self.probe = probe
        // Every change, also from the keyboard: the open island stays open through it. Only NSWorkspace's own
        // center posts it.
        spaceChange = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    /// A list appeared: the desktops are read now, and again whenever the desktop in front changes, while
    /// any list shows.
    func appeared() {
        viewers += 1
        guard viewers == 1 else { return }
        problem = nil
        reload()
    }

    func disappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        problem = nil
    }

    /// The open island lost the keyboard: whether that is the desktop changing under it (a jump, or ⌃← ⌃→),
    /// and not a click elsewhere. Only the first loss of each change is.
    func keyboardLostToADesktopChange() -> Bool {
        switchGrace.keyboardLost(at: now)
    }

    /// Jumps to the desktop with `id`, from the one in front as the system says now.
    func jump(to id: UInt64) {
        guard !isJumping else { return }
        reload()
        guard let spaces, let current = spaces.firstIndex(where: \.isCurrent), let target = spaces.firstIndex(where: { $0.id == id })
        else { return }
        perform { await $0.jump(from: current, to: target) }
    }

    /// One desktop to the left or the right, without a list.
    func step(_ direction: SpaceDirection) {
        guard !isJumping else { return }
        perform { await $0.step(direction) }
    }

    /// "Give Permission…": the system's prompt the first time (it already offers to open System Settings),
    /// System Settings after that, asked again first in case macOS forgot Toma; never both (plan decision 27). The island gets out of the way of either.
    func givePermission() {
        switch PermissionAction(for: probe.state(of: .accessibility)) {
        case nil:
            // Allowed meanwhile: the next jump posts.
            problem = nil
        case .prompt:
            send(.systemUIOpened)
            Task { _ = await probe.request(.accessibility) }
        case .openSettings:
            send(.systemUIOpened)
            Task { await PermissionSettingsOpener.live(probe: probe).open(.accessibility) }
        }
    }

    /// Mission Control, with the island out of the way of its bar of desktops.
    func openMissionControl() {
        send(.systemUIOpened)
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Mission Control.app"))
    }

    private func perform(_ jump: @escaping @MainActor (SpaceJumper) async -> SpaceJumper.Outcome) {
        isJumping = true
        switchGrace.jumpBegan()
        Task {
            let outcome = await jump(jumper)
            isJumping = false
            let problem: Problem? =
                switch outcome {
                case .jumped, .alreadyThere: nil
                case .needsAccessibility: .needsAccessibility
                case .shortcutsOff: .shortcutsOff
                }
            if case .jumped = outcome {
                switchGrace.jumpEnded(posted: true, at: now)
            } else {
                switchGrace.jumpEnded(posted: false, at: now)
            }
            if self.problem != problem { self.problem = problem }
        }
    }

    private var now: Duration { ContinuousClock.now - origin }

    private func spaceChanged() {
        switchGrace.spaceChanged(at: now)
        if viewers > 0 { reload() }
    }

    private func reload() {
        let display = SpacesReader.displayUUID(for: displayID).flatMap { uuid in
            SpacesReader.live.snapshot().flatMap { DesktopSpaces.spaces(forDisplayUUID: uuid, in: $0) }
        }
        // Without the one in front there is nothing to jump from.
        let spaces = display.flatMap { $0.spaces.contains(where: \.isCurrent) ? $0.spaces : nil }
        if self.spaces != spaces { self.spaces = spaces }
    }
}

/// The island display's desktops by name, the one in front highlighted, as a selector (the selector
/// spring); a tap jumps there. Without a list, ← → (and Mission Control, in the column). In the open
/// panel's first column (Display) with the note "Recording follows the desktop in front."; in the open
/// recording island, in the row of controls, whose Mission Control button is always there.
struct DesktopsList: View {
    enum Layout {
        case column, row
    }

    let model: DesktopsModel
    let layout: Layout

    var body: some View {
        Group {
            switch layout {
            case .column:
                VStack(alignment: .leading, spacing: 6) {
                    if let spaces = model.spaces {
                        selector(spaces)
                    } else {
                        HStack(spacing: 6) {
                            arrows
                            Button { model.openMissionControl() } label: {
                                Label("Mission Control", systemImage: "rectangle.3.group")
                            }
                            .buttonStyle(GlassButtonStyle(compact: true))
                        }
                    }
                    Text("Recording follows the desktop in front.")
                        .font(.system(size: 11))
                        .opacity(0.62)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .row:
                HStack(spacing: 8) {
                    if let spaces = model.spaces { selector(spaces) } else { arrows }
                }
            }
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    /// Its natural width when it fits; otherwise it scrolls sideways.
    private func selector(_ spaces: [DesktopSpace]) -> some View {
        let segmented = GlassSegmented(
            items: spaces.map { GlassSegmented.Item(value: $0.id, title: Self.title(of: $0.label)) },
            selection: Binding(
                get: { spaces.first(where: \.isCurrent)?.id ?? 0 },
                set: { model.jump(to: $0) }),
            compact: true)
        return ViewThatFits(in: .horizontal) {
            segmented.fixedSize()
            ScrollView(.horizontal) { segmented }
                .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var arrows: some View {
        switch layout {
        case .column:
            ArrowButton(symbol: "arrow.left", title: String(localized: "Previous Desktop")) { model.step(.left) }
            ArrowButton(symbol: "arrow.right", title: String(localized: "Next Desktop")) { model.step(.right) }
        case .row:
            RoundControl(symbol: "arrow.left", title: String(localized: "Previous Desktop")) { model.step(.left) }
            RoundControl(symbol: "arrow.right", title: String(localized: "Next Desktop")) { model.step(.right) }
        }
    }

    /// As Mission Control names it: "Desktop 2", the app in full screen (with its window's title when the app
    /// has several), or the apps side by side.
    static func title(of label: DesktopSpace.Label) -> Text {
        switch label {
        case .desktop(let number?):
            Text("Desktop \(number)", comment: "A desktop (Space) among several: its number, as Mission Control names it")
        case .desktop(nil):
            Text("Desktop", comment: "A display's only desktop (Space), and the open island's section of desktops")
        case .fullScreen(let app, let title):
            Text(verbatim: windowName(app: app, title: title))
        case .splitView(let apps):
            Text(verbatim: ListFormatter.localizedString(byJoining: apps))
        }
    }
}

/// A small round glass button with a symbol, its title as help and for VoiceOver.
private struct ArrowButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(GlassButtonStyle(shape: .circle))
        .accessibilityLabel(Text(verbatim: title))
        .help(title)
    }
}

/// Why a jump posted nothing and how to fix it, in amber: Accessibility (with "Give Permission…"), or the
/// shortcuts off in System Settings.
struct DesktopsProblemRow: View {
    let model: DesktopsModel
    let problem: DesktopsModel.Problem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: NoticePresentation.attention.symbol)
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(NoticePresentation.attention.tint)
                .accessibilityHidden(true)
            message
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1, green: 0.89, blue: 0.72))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if problem == .needsAccessibility {
                Button { model.givePermission() } label: { Text("Give Permission…") }
                    .buttonStyle(GlassButtonStyle(compact: true))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NoticePresentation.attention.tint.opacity(0.16))
        }
    }

    private var message: Text {
        switch problem {
        case .needsAccessibility:
            Text("To switch desktops from here, Toma needs the Accessibility permission. ⌃← and ⌃→ work the same from the keyboard.")
        case .shortcutsOff:
            Text(
                "To switch desktops from here, turn on “Move left a space” and “Move right a space” in System Settings › Keyboard › Keyboard Shortcuts › Mission Control.",
                comment: "The names of the settings as macOS shows them in each language")
        }
    }
}
