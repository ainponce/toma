// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Observation
import SwiftUI

/// What the island's SwiftUI content shows; `IslandPanel` keeps it up to date.
@MainActor @Observable
final class IslandModel {
    /// The state whose content is shown; changed inside an animation, so contents come and go with
    /// their transitions.
    var state = IslandState.rest
    /// The screen the island is on.
    var top: ScreenTop
    /// The outline as it is on screen at this moment, while the spring moves it.
    var outline: IslandShape
    var reduceMotion: Bool
    var reduceTransparency: Bool
    /// The open panel's choices, while the island is open or choosing.
    var panel: OpenPanelModel?

    /// What the content does to the island.
    @ObservationIgnored var send: (IslandEvent) -> Void = { _ in }

    init(top: ScreenTop, reduceMotion: Bool, reduceTransparency: Bool) {
        self.top = top
        outline = IslandGeometry.shape(.rest, on: top)
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    /// Under the notch, the band at the top where nothing can be seen.
    var notchBand: Double { top.notch == nil ? 0 : top.menuBarHeight }
}

/// The island's content, cut to its outline on its surface. Only the outline changes on every frame of
/// the spring; the content of each state keeps the size of its state and is cut while the island grows
/// or shrinks.
struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let outline = model.outline
        IslandContent(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .islandGlass(
                IslandOutline(outline), black: isBlack, topBand: model.notchBand, reduceTransparency: model.reduceTransparency)
            .environment(\.colorScheme, .dark)
    }

    /// At rest, and peeking, under the notch the island is all black, like the notch.
    private var isBlack: Bool {
        guard model.top.notch != nil else { return false }
        switch model.state {
        case .rest, .peek: return true
        case .open, .choosing: return false
        }
    }
}

/// The content of the current state; the one that is left fades out while the new one appears.
private struct IslandContent: View {
    let model: IslandModel

    var body: some View {
        let shape = IslandGeometry.shape(model.state, on: model.top)
        ZStack(alignment: .top) {
            content(model.state)
                .frame(width: shape.width, height: shape.height, alignment: .top)
                .id(Self.key(model.state))
                .transition(model.reduceMotion ? .islandFade : .islandContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Which content a state shows: a new key is a new content, with its transition.
    private static func key(_ state: IslandState) -> Int {
        switch state {
        case .rest: 0
        case .peek: 1
        case .open: 2
        case .choosing: 3
        }
    }

    @ViewBuilder
    private func content(_ state: IslandState) -> some View {
        switch state {
        case .rest:
            // Nothing to see: under a notch, a click opens it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.send(.clicked) }
        case .peek:
            BelowTheNotch(band: model.notchBand) { PeekRow() }
                .contentShape(Rectangle())
                .onTapGesture { model.send(.clicked) }
        case .open:
            if let panel = model.panel {
                IslandOpenPanel(panel: panel, topInset: model.notchBand, send: model.send)
            }
        case .choosing:
            BelowTheNotch(band: model.notchBand) { ChoosingRow(send: model.send) }
        }
    }
}

/// Centers its content in what is left under the notch's band.
private struct BelowTheNotch<Content: View>: View {
    let band: Double
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: band)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The record icon, "New Recording" and the island's shortcut.
private struct PeekRow: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "record.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
                .font(.system(size: 12))
            Text("New Recording")
                .font(.system(size: 12, weight: .medium))
            // Task 16a shows the configured shortcut's displayString.
            KeyCap(text: "⇧⌘2")
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
}

/// While choosing on the screen: what to do, how to go back, and Done.
private struct ChoosingRow: View {
    let send: (IslandEvent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12))
            Text("Click a display to record it.")
                .font(.system(size: 12, weight: .medium))
            KeyCap(text: String(localized: "Esc to go back"))
            Button { send(.endedChoosing) } label: {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color(nsColor: .systemBlue)))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A shortcut or key, as a small light cap.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10.5))
            .opacity(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
    }
}

extension AnyTransition {
    /// A state's content materializing (opacity 0 → 1, blur 10 → 0, scale 0.94 → 1 with the opening spring,
    /// 60 ms after the island starts to change) and fading out (170 ms, blur 0 → 8). Notch design §5.3.
    static var islandContent: AnyTransition {
        let enter = Motion.islandExpand
        return .asymmetric(
            insertion: .modifier(
                active: Materialized(opacity: 0, blur: Motion.contentEnterBlur, scale: Motion.contentEnterScale),
                identity: Materialized(opacity: 1, blur: 0, scale: 1)
            )
            .animation(.spring(response: enter.response, dampingFraction: enter.damping).delay(Motion.contentDelay.timeInterval)),
            removal: .modifier(
                active: Materialized(opacity: 0, blur: Motion.contentExitBlur, scale: 1),
                identity: Materialized(opacity: 1, blur: 0, scale: 1)
            )
            .animation(.easeIn(duration: Motion.contentExit.timeInterval)))
    }

    /// With "Reduce motion": a fade, without scale or blur.
    static var islandFade: AnyTransition {
        .opacity.animation(.easeInOut(duration: Motion.reducedMotionFade.timeInterval))
    }
}

private struct Materialized: ViewModifier {
    let opacity: Double
    let blur: Double
    let scale: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .top)
    }
}
