// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import SwiftUI

extension EnvironmentValues {
    /// "Reduce motion", as the island last read it (`NSWorkspace`): every motion inside it becomes a fade.
    @Entry var islandReduceMotion = false
}

extension Animation {
    /// `spring`, or with "Reduce motion" the design's 200 ms fade, without scale or bounce.
    static func island(_ spring: AppSupport.Spring, reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: Motion.reducedMotionFade.timeInterval)
            : .spring(response: spring.response, dampingFraction: spring.damping)
    }
}

/// A segmented control with a sliding glass indicator (the selector spring); with "Reduce motion" the
/// indicator fades from one segment to the other.
struct GlassSegmented<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: Text
        var icon: String?
        /// Drawn disabled, with this help.
        var disabledHelp: String?
    }

    let items: [Item]
    @Binding var selection: Value
    var compact = false
    @Namespace private var namespace
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                if let help = item.disabledHelp {
                    segment(item).disabledWithHelp(help)
                } else {
                    segment(item)
                }
            }
        }
        .padding(3)
        .background {
            Capsule().fill(Color.white.opacity(0.07)).overlay(Capsule().stroke(Color.white.opacity(0.11)))
        }
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: selection)
    }

    private func segment(_ item: Item) -> some View {
        let isOn = selection == item.value
        return Button { selection = item.value } label: {
            HStack(spacing: 6) {
                if let icon = item.icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
                item.title
            }
            .font(.system(size: compact ? 12 : 13))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 3 : 5)
            .opacity(isOn ? 1 : 0.7)
            .background {
                if isOn {
                    let indicator = Capsule().fill(Color.white.opacity(0.24))
                    if reduceMotion {
                        indicator.transition(.opacity)
                    } else {
                        indicator.matchedGeometryEffect(id: "indicator", in: namespace)
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The island's glass buttons; pressed, they shrink a little (not with "Reduce motion").
struct GlassButtonStyle: ButtonStyle {
    enum Outline { case capsule, circle }

    var shape = Outline.capsule
    var compact = false
    var isOn = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13))
            .lineLimit(1)
            .padding(.horizontal, shape == .circle ? 0 : (compact ? 10 : 13))
            .padding(.vertical, shape == .circle ? 0 : (compact ? 4 : 6))
            .background {
                let fill = Color.white.opacity(isOn ? 0.26 : (configuration.isPressed ? 0.19 : 0.10))
                switch shape {
                case .capsule: Capsule().fill(fill).overlay(Capsule().stroke(Color.white.opacity(0.15)))
                case .circle: Circle().fill(fill).overlay(Circle().stroke(Color.white.opacity(0.15)))
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.32)
            .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Record: red, the one prominent button.
struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.leading, 14)
            .padding(.trailing, 18)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(isEnabled
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 1, green: 0.35, blue: 0.31), Color(red: 0.9, green: 0.21, blue: 0.17)],
                            startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color(red: 0.36, green: 0.19, blue: 0.18)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.28)))
            }
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: configuration.isPressed)
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
