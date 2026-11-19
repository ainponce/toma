// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import SwiftUI

extension AppSupport.Spring {
    /// The SwiftUI animation of the spring (`.spring(response:dampingFraction:)` takes the same two numbers).
    var animation: Animation {
        .spring(response: response, dampingFraction: damping)
    }
}

extension Animation {
    /// `spring` for a change of the interface, or, with "Reduce motion", `Motion.reducedMotionFade`: a fade without scale
    /// or bounce.
    static func panel(_ spring: AppSupport.Spring, reduceMotion: Bool) -> Animation {
        let fade = Motion.reducedMotionFade.components
        return reduceMotion ? .easeInOut(duration: Double(fade.seconds) + Double(fade.attoseconds) / 1e18) : spring.animation
    }
}

extension View {
    /// A control of the panel with its title above it, as wide as the panel: a segmented control's title beside it would be
    /// squeezed in the panel's width (Spanish is long). VoiceOver reads the control's own label, not the title twice.
    func panelTitled(_ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .accessibilityHidden(true)
            labelsHidden()
        }
    }
}

/// A titled group of controls of the panel.
struct PanelSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
    }
}

/// A slider that shows an integer from 0 to 100 (design §5.4) and whose value the document keeps as the render's measure.
/// Dragging it is a gesture of the model (the preview follows, one edit at the end); the arrow keys are steps of their
/// own, which the session joins into one undo when they come in a burst. It is read as "Padding, 40".
struct PanelSlider: View {
    let title: LocalizedStringKey
    let model: EditorModel
    /// The document's value as the slider shows it.
    let value: Int
    var range: ClosedRange<Int> = PanelValues.sliderRange
    /// What follows the number ("%"); the number alone is what a screen reader reads.
    var unit = ""
    let set: (Int) -> Void

    @State private var dragged: Int?

    var body: some View {
        let shown = dragged ?? value
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: "\(shown)\(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(shown) },
                    set: { newValue in
                        let integer = Int(newValue.rounded())
                        guard integer != shown else { return }
                        dragged = integer
                        set(integer)
                    }),
                in: Double(range.lowerBound)...Double(range.upperBound), step: 1,
                onEditingChanged: { editing in
                    if editing {
                        model.beginGesture()
                    } else {
                        model.endGesture()
                        dragged = nil
                    }
                }
            )
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: "\(shown)"))
        }
        // A keyboard step is not a drag: once the document has it, the slider shows the document's.
        .onChange(of: value) { _, _ in
            if !model.isGesturing { dragged = nil }
        }
    }
}

/// The small tile of a grid of choices (a wallpaper, a gradient, a colour): a swatch with a ring when it is the chosen one.
struct PanelTile<Swatch: View>: View {
    let name: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let swatch: Swatch

    var body: some View {
        Button(action: action) {
            swatch
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .help(Text(name))
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A bar over a range of decimals (the automatic zoom's settings, a zoom's depth): its value reads as `format` says and
/// lands once, when the drag ends (a change of them plans the zooms again, which a drag must not do at every step); an
/// arrow key is a step of its own.
struct PanelStepSlider: View {
    let title: LocalizedStringKey
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let commit: (Double) -> Void

    @State private var dragged: Double?
    @State private var editing = false

    var body: some View {
        let shown = dragged ?? value
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { shown },
                    set: { new in
                        let snapped = min(max((new / step).rounded() * step, range.lowerBound), range.upperBound)
                        if editing {
                            dragged = snapped
                        } else if abs(snapped - value) > step / 2 {
                            commit(snapped)
                        }
                    }),
                in: range, step: step,
                onEditingChanged: { began in
                    editing = began
                    if !began, let last = dragged {
                        dragged = nil
                        if abs(last - value) > step / 2 { commit(last) }
                    }
                }
            )
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: format(shown)))
        }
    }
}
