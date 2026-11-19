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
/// indicator fades from one segment to the other. With `scrolls`, segments that don't fit scroll sideways
/// inside the track, faded at an edge that has more past it, and the chosen one is kept in view.
struct GlassSegmented<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: Text
        var icon: String?
        /// Drawn disabled, with this help.
        var disabledHelp: String?
        /// Only the icon is drawn; the title is its help and what VoiceOver reads.
        var iconOnly = false
    }

    let items: [Item]
    @Binding var selection: Value
    var compact = false
    /// As wide as it is offered: each segment its own width and an equal share of what is left.
    var fills = false
    var scrolls = false
    /// A title wider than this is cut, and shows whole as its help (a desktop named after a window).
    var maxTitleWidth: Double?
    @Namespace private var namespace
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if scrolls {
                ScrollingSegments(values: items.map(\.value), selection: selection) { segments }
            } else {
                segments
            }
        }
        .padding(3)
        .background {
            Capsule().fill(Color.white.opacity(0.07)).overlay(Capsule().stroke(Color.white.opacity(0.11)))
        }
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: selection)
    }

    private var segments: some View {
        let layout = fills && !scrolls ? AnyLayout(FillingRow(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Group {
                    if let help = item.disabledHelp {
                        segment(item).disabledWithHelp(help)
                    } else {
                        segment(item)
                    }
                }
                .id(item.value)
            }
        }
    }

    @ViewBuilder
    private func segment(_ item: Item) -> some View {
        if item.iconOnly {
            button(item).help(item.title).accessibilityLabel(item.title)
        } else if maxTitleWidth != nil {
            button(item).help(item.title)
        } else {
            button(item)
        }
    }

    private func button(_ item: Item) -> some View {
        let isOn = selection == item.value
        return Button { selection = item.value } label: {
            HStack(spacing: 6) {
                if let icon = item.icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
                if !item.iconOnly {
                    item.title
                        .truncationMode(.tail)
                        .frame(maxWidth: maxTitleWidth.map { CGFloat($0) })
                }
            }
            .font(.system(size: compact ? 12 : 13))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 3 : 5)
            .frame(maxWidth: fills ? .infinity : nil)
        }
        .buttonStyle(SegmentStyle(isOn: isOn) {
            if isOn {
                let indicator = Capsule().fill(Color.white.opacity(0.22)).shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                if reduceMotion {
                    indicator.transition(.opacity)
                } else {
                    indicator.matchedGeometryEffect(id: "indicator", in: namespace)
                }
            }
        })
    }
}

/// A row whose items each get their own width and an equal share of what is left of the width offered; when they
/// don't fit, their own widths.
private struct FillingRow: Layout {
    let spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing * Double(max(subviews.count - 1, 0))
        // Asked for its ideal or its largest size, its own widths.
        let width = proposal.width.flatMap { $0.isFinite ? max($0, natural) : nil } ?? natural
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing * Double(subviews.count - 1)
        let share = max(bounds.width - natural, 0) / Double(subviews.count)
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            let width = size.width + share
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// A segment: full white once chosen, brighter under the pointer, a little dimmer while pressed.
private struct SegmentStyle<Indicator: View>: ButtonStyle {
    let isOn: Bool
    @ViewBuilder let indicator: Indicator

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, isOn: isOn, indicator: indicator)
    }
}

private struct SegmentBody<Indicator: View>: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let indicator: Indicator
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .opacity(labelOpacity)
            .background {
                indicator
                if !isOn, isHovered, isEnabled {
                    Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.05 : 0.08))
                }
            }
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.island(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
            .animation(.island(Motion.hover, reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var labelOpacity: Double {
        guard isEnabled else { return 0.3 }
        if isOn { return 1 }
        if configuration.isPressed { return 0.55 }
        return isHovered ? 0.9 : 0.68
    }
}

/// Segments that may not fit: they scroll sideways, faded at an edge that has more past it, and the chosen one
/// is scrolled into view when they appear and whenever it changes.
private struct ScrollingSegments<Value: Hashable, Content: View>: View {
    /// The segments' values, in their order.
    let values: [Value]
    let selection: Value
    @ViewBuilder let content: Content
    @State private var overflow = Overflow()
    @Environment(\.islandReduceMotion) private var reduceMotion

    /// How wide an edge fades.
    private static var fade: Double { 18 }
    private static var slack: Double { 3 }

    /// Whether there is more past each edge.
    private struct Overflow: Equatable {
        var leading = false
        var trailing = false
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) { content }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Overflow.self) { geometry in
                    let visible = geometry.visibleRect
                    // A point or two off an end is the island's content settling, not more to see.
                    return Overflow(
                        leading: visible.minX > Self.slack, trailing: visible.maxX < geometry.contentSize.width - Self.slack)
                } action: { _, new in
                    overflow = new
                }
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(overflow.leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.fade)
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(overflow.trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.fade)
                    }
                    .animation(.island(Motion.hover, reduceMotion: reduceMotion), value: overflow)
                }
                .onAppear {
                    // The first one is in view as it is. Others once laid out: before, there is nothing to scroll.
                    guard selection != values.first else { return }
                    Task { proxy.scrollTo(selection, anchor: .center) }
                }
                .onChange(of: selection) {
                    // With "Reduce motion" it is there at once.
                    if reduceMotion {
                        proxy.scrollTo(selection, anchor: .center)
                    } else {
                        withAnimation(.island(Motion.selector, reduceMotion: false)) { proxy.scrollTo(selection, anchor: .center) }
                    }
                }
        }
    }
}

/// The island's glass buttons: brighter under the pointer, and pressed they shrink a little (not with
/// "Reduce motion").
struct GlassButtonStyle: ButtonStyle {
    enum Outline { case capsule, circle }

    var shape = Outline.capsule
    var compact = false
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, shape: shape, compact: compact, isOn: isOn)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: GlassButtonStyle.Outline
    let compact: Bool
    let isOn: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13))
            .lineLimit(1)
            .padding(.horizontal, shape == .circle ? 0 : (compact ? 10 : 13))
            .padding(.vertical, shape == .circle ? 0 : (compact ? 4 : 6))
            .background {
                let fill = Color.white.opacity(fillOpacity)
                let stroke = Color.white.opacity(isOn ? 0.22 : 0.13)
                switch shape {
                case .capsule: Capsule().fill(fill).overlay(Capsule().stroke(stroke))
                case .circle: Circle().fill(fill).overlay(Circle().stroke(stroke))
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.32)
            .onHover { isHovered = $0 }
            .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(.island(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
    }

    private var fillOpacity: Double {
        if configuration.isPressed { return isOn ? 0.30 : 0.19 }
        if isOn { return 0.24 }
        return isHovered && isEnabled ? 0.145 : 0.09
    }
}

/// Record: red, the one prominent button; brighter under the pointer.
struct RecordButtonStyle: ButtonStyle {
    /// The island's record red, a touch deeper than the recording dot so white reads on it (Record, Stop).
    static let red = Color(red: 0.93, green: 0.25, blue: 0.22)

    func makeBody(configuration: Configuration) -> some View {
        RecordButtonBody(configuration: configuration)
    }
}

private struct RecordButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .padding(.leading, 14)
            .padding(.trailing, 18)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(isEnabled ? RecordButtonStyle.red : Color(red: 0.36, green: 0.19, blue: 0.18))
                    .brightness(isEnabled ? (configuration.isPressed ? -0.06 : (isHovered ? 0.05 : 0)) : 0)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(isEnabled ? 0.22 : 0.1)))
            }
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .onHover { isHovered = $0 }
            .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(.island(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
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
