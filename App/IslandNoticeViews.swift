// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Foundation
import Observation
import ProjectFormat
import SwiftUI

// MARK: - The capsule

/// A short confirmation under the island (notch design §5.1): a glass capsule that hangs 10 pt below it for
/// `IslandConfirmation.displayDuration`, following it while it grows or shrinks; while the teleprompter
/// shows, 10 pt below the teleprompter instead, so neither covers the other. It is never key and lets the
/// mouse through, unless it has an action (the trash's notice opens the library's trash); a new one replaces the one
/// showing.
@MainActor
final class ConfirmationCapsule {
    /// Between the bottom edge of what it hangs from and the capsule's top.
    private static let gap = 10.0
    /// How far below what it hangs from a capsule reaches, with the same gap after it: what is placed under the
    /// island while one may show keeps clear of it (the area bar).
    static var clearance: Double { 2 * gap + CapsuleLabel.height }

    var reduceMotion = false {
        didSet { model.reduceMotion = reduceMotion }
    }
    var reduceTransparency = false {
        didSet { model.reduceTransparency = reduceTransparency }
    }

    private let model = CapsuleModel()
    private let panel: FloatingPanel
    /// The frame of what it hangs from (the island, or the teleprompter under it) as it is now.
    private var anchor = CGRect.zero
    /// The capsule showing, or the last one.
    private var size = CGSize.zero
    /// Hides the capsule once its time is up, then takes the panel off the screen.
    private var timer: Task<Void, Never>?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel = FloatingPanel(contentRect: frame, level: FloatingPanel.floatingLevel, ignoresMouseEvents: true)
        let content = FloatingHostingView.make(CapsuleView(model: model))
        content.frame = frame
        panel.contentView = content
    }

    func show(_ item: CapsuleItem) {
        size = CapsuleLabel.size(of: item)
        place()
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.ignoresMouseEvents = item.action == nil
        withAnimation(animation) { model.item = item }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: item.duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// What it hangs from (the island, or the teleprompter under it) is now at `anchor`.
    func follow(_ anchor: CGRect) {
        guard anchor != self.anchor else { return }
        self.anchor = anchor
        if panel.isVisible { place() }
    }

    private func hide() {
        withAnimation(animation) { model.item = nil }
        let exit = reduceMotion ? Motion.reducedMotionFade : Motion.contentExit
        timer = Task { [weak self] in
            try? await Task.sleep(for: exit)
            guard !Task.isCancelled, let self, model.item == nil else { return }
            panel.orderOut(nil)
        }
    }

    private var animation: Animation {
        .island(Motion.islandExpand, reduceMotion: reduceMotion)
    }

    /// Centered under what it hangs from, `gap` below it.
    private func place() {
        let frame = NSRect(
            x: (anchor.midX - size.width / 2).rounded(), y: anchor.minY - Self.gap - size.height,
            width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }
}

/// What a capsule says: an icon and a sentence.
struct CapsuleItem: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
    var tint = Color.white
    /// What a click on the capsule does; `nil`: the capsule lets the mouse through.
    var action: (() -> Void)?
    /// How long it shows.
    var duration = IslandConfirmation.displayDuration
}

extension IslandConfirmation {
    var capsule: CapsuleItem {
        switch self {
        case .markerAdded: CapsuleItem(symbol: "flag.fill", text: String(localized: "Marker added."))
        case .paused: CapsuleItem(symbol: "pause.fill", text: String(localized: "Paused."), tint: NoticePresentation.attention.tint)
        case .movedToTrash: CapsuleItem(symbol: "trash", text: String(localized: "The take went to the trash."))
        case .countdownCancelled: CapsuleItem(symbol: "xmark", text: String(localized: "Countdown cancelled."))
        case .areaSaved: CapsuleItem(symbol: "bookmark.fill", text: String(localized: "Area saved."))
        }
    }
}

extension TakeNotice {
    /// A notice that confirms (a source that came back), as the capsule says it.
    var capsule: CapsuleItem {
        CapsuleItem(symbol: "checkmark", text: text(closeError: nil), tint: NoticePresentation.confirmation.tint)
    }
}

@MainActor @Observable
private final class CapsuleModel {
    var item: CapsuleItem?
    var reduceMotion = false
    var reduceTransparency = false
}

/// The capsule showing appears as the island's contents do, and fades out when its time is up.
private struct CapsuleView: View {
    let model: CapsuleModel

    var body: some View {
        ZStack {
            if let item = model.item {
                CapsuleLabel(item: item, reduceTransparency: model.reduceTransparency)
                    .contentShape(Rectangle())
                    .onTapGesture { item.action?() }
                    .accessibilityAddTraits(item.action == nil ? [] : .isButton)
                    .id(item.id)
                    .transition(model.reduceMotion ? .islandFade : .islandContent)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .environment(\.islandReduceMotion, model.reduceMotion)
    }
}

private struct CapsuleLabel: View {
    static let height = 32.0

    let item: CapsuleItem
    let reduceTransparency: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.tint)
                .accessibilityHidden(true)
            Text(verbatim: item.text)
                .font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 15)
        .frame(height: Self.height)
        .islandGlass(
            IslandOutline(IslandShape(width: 0, height: Self.height, bottomRadius: Self.height / 2, roundsTopCorners: true)),
            black: false, topBand: 0, reduceTransparency: reduceTransparency)
    }

    /// The size the capsule of `item` takes, in whole points.
    @MainActor static func size(of item: CapsuleItem) -> CGSize {
        let fitting = NSHostingView(rootView: CapsuleLabel(item: item, reduceTransparency: true)).fittingSize
        return CGSize(width: fitting.width.rounded(.up), height: height)
    }
}

// MARK: - Notices in the island

extension NoticePresentation {
    /// Green for a confirmation, amber for a notice that asks for attention, red once the take stopped.
    var tint: Color {
        switch self {
        case .confirmation: Color(red: 0.2, green: 0.84, blue: 0.29)
        case .attention: Color(red: 1, green: 0.7, blue: 0.25)
        case .stopped: Color(red: 1, green: 0.27, blue: 0.23)
        }
    }

    var symbol: String {
        switch self {
        case .confirmation: "checkmark.circle.fill"
        case .attention, .stopped: "exclamationmark.triangle.fill"
        }
    }
}

/// A notice as the island says it: its icon, in its color, and its sentence.
struct IslandNoticeLine: View {
    let notice: TakeNotice
    /// What `closedWithError` is about.
    let closeError: (any Error)?
    var size = 12.0
    var lineLimit = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: notice.presentation.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(notice.presentation.tint)
                .accessibilityHidden(true)
            Text(verbatim: notice.text(closeError: closeError))
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
        }
        .font(.system(size: size, weight: .medium))
    }
}

/// The open recording island's notices that ask for attention, oldest first, until they are resolved.
struct IslandNoticeList: View {
    let notices: [TakeNotice]
    let closeError: (any Error)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                    IslandNoticeLine(notice: notice, closeError: closeError, size: 11.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Saving and saved

/// While the take closes (490 × 140): "Saving the take", with an indicator.
struct IslandSavingView: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving the take")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Closing each track's files")
                .font(.system(size: 11.5))
                .opacity(0.65)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A take saved (490 × 140): "Take saved", how long it is, its markers and its tracks, and why it stopped if
/// it stopped by itself or closed with an error. When its editor did not open ("Stay Where I Am"): Open in
/// the Editor · Record Another · Close. A save of the Replay (`SavedTake.replaySeconds`, fases 4 y 5 design §10.3):
/// «Saved: Last 30 s», its project's name and its tracks, and Open · Close.
struct IslandSavedView: View {
    let take: SavedTake
    let recording: RecordingController
    /// Under the notch, the black band at the top.
    let topInset: Double
    let send: (IslandEvent) -> Void
    /// Opens a project in the editor: the Replay's.
    let openProject: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(NoticePresentation.confirmation.tint)
                    .accessibilityHidden(true)
                if let seconds = take.replaySeconds {
                    Text("Saved: Last \(ReplayText.length(seconds))", comment: "The island once the Replay saved its last seconds: «30 s», «1 min»")
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Text("Take saved")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            if take.replaySeconds != nil {
                replayDetails
                replayActions
            } else {
                details
                if let stopped = recording.notices.last(where: { $0.presentation == .stopped }) {
                    IslandNoticeLine(notice: stopped, closeError: recording.lastCloseError, size: 11.5, lineLimit: 1)
                }
                if !take.openedEditor { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset + 10)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }

    /// Its time, its markers and its tracks.
    private var details: some View {
        HStack(spacing: 6) {
            Text(verbatim: take.duration.recordedTime)
                .monospacedDigit()
            Dot()
            Text("\(take.markers) markers")
            if let tracks = take.trackNames {
                Dot()
                Text(verbatim: tracks)
            }
        }
        .font(.system(size: 11.5))
        .opacity(0.65)
        .lineLimit(1)
    }

    /// The Replay's project, by its name in the library, and its tracks.
    private var replayDetails: some View {
        HStack(spacing: 6) {
            Text(verbatim: take.projectURL.deletingPathExtension().lastPathComponent)
                .truncationMode(.middle)
            if let tracks = take.trackNames {
                Dot()
                Text(verbatim: tracks)
                    .layoutPriority(1)
            }
        }
        .font(.system(size: 11.5))
        .opacity(0.65)
        .lineLimit(1)
    }

    private var replayActions: some View {
        HStack(spacing: 8) {
            Button {
                openProject(take.projectURL)
                send(.dismiss)
            } label: {
                Text("Open", comment: "The island once the Replay saved: opens its project in the editor")
            }
            Spacer(minLength: 0)
            Button { send(.dismiss) } label: { Text("Close") }
        }
        .buttonStyle(GlassButtonStyle(compact: true))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                recording.openLastProject()
                send(.dismiss)
            } label: {
                Text("Open in the Editor")
            }
            Button { send(.toggle) } label: {
                Label {
                    Text("Record Another")
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(NoticePresentation.stopped.tint)
                }
            }
            Spacer(minLength: 0)
            Button { send(.dismiss) } label: { Text("Close") }
        }
        .buttonStyle(GlassButtonStyle(compact: true))
    }
}

/// The separator between the saved take's details.
private struct Dot: View {
    var body: some View {
        Text(verbatim: "·").accessibilityHidden(true)
    }
}

extension SavedTake {
    /// The kinds of its tracks, each once, as a list ("Display and Microphone"); `nil` when it has none.
    var trackNames: String? { TrackKind.listed(trackKinds) }
}

extension TrackKind {
    /// `kinds`, each once, as a list ("Display and Microphone"), in their order; `nil` when there are none. Also Settings ▸
    /// Replay's sources.
    static func listed(_ kinds: [TrackKind]) -> String? {
        var unique: [TrackKind] = []
        for kind in kinds where !unique.contains(kind) { unique.append(kind) }
        guard !unique.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: unique.map(\.savedTakeName))
    }

    /// How the saved take names a track of this kind: the open panel's names.
    fileprivate var savedTakeName: String {
        switch self {
        case .display: String(localized: "Display", comment: "What to record: a whole display")
        case .window: String(localized: "Window", comment: "What to record: one window")
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .systemAudio: String(localized: "System Audio")
        case .device: String(localized: "iPhone or iPad", comment: "What a saved take recorded: the screen of an iPhone or iPad")
        case .deviceAudio: String(localized: "iPhone or iPad Audio", comment: "What a saved take recorded: the sound of an iPhone or iPad")
        }
    }
}
