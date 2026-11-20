// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import ProjectFormat
import SwiftUI

/// "Speed Up Typing…" (phase 2 design §7.5): the speed (2× · 3× · 4× · 8×, 3× chosen), what it gives, and the step that
/// does it. The model shows it from Edit and from the Video track's menu.
extension EditorModel {
    /// Shows the little window of Speed Up Typing.
    func askTypingSpeed() {
        guard canEdit else { return }
        isAskingTypingSpeed = true
    }

    /// What `speed` gives on the project as it is now, over every take of the sequence (plan 3d decision 17), worked out
    /// off the main thread (it reads the events of the takes); `nil` if the project is not open.
    func typingSpeedSummary(speed: Double) async -> TypingSpeed.Summary? {
        guard let document, let project = overlayProject else { return nil }
        return await Task.detached(priority: .userInitiated) {
            TypingSpeed.summary(document, takes: Self.typingTakes(project, document), speed: speed)
        }.value
    }

    /// Speeds the stretches of typing of every take of the sequence up to `speed`, in one step. Worked out off the main
    /// thread and applied if the document is the one it was worked out on.
    func speedUpTyping(speed: Double) {
        guard canEdit, let document, let project = overlayProject else { return }
        Task {
            let step = await Task.detached(priority: .userInitiated) {
                TypingSpeed.apply(document, takes: Self.typingTakes(project, document), speed: speed) { prefix in
                    prefix + String(format: "%08x", UInt32.random(in: .min ... .max))
                }
            }.value
            guard let step, self.document == document else { return }
            perform(step)
        }
    }

    /// Each take `document`'s sequence shows, with its events (`LoadedProject.takesShown(by:)`): reads those of a take
    /// that has not read them yet, so never on the main thread.
    private nonisolated static func typingTakes(_ project: LoadedProject, _ document: EditDocument) -> [(TakeRecord, [InputEvent])] {
        project.takesShown(by: document).map { ($0.take, $0.events) }
    }
}

/// The popover: a segmented control of speeds, the result live, and Cancel / Speed Up.
struct TypingSpeedPopover: View {
    let model: EditorModel
    @State private var speed = TypingSpeed.defaultSpeed
    /// What `speed` gives; `nil` while it is worked out.
    @State private var summary: TypingSpeed.Summary?

    static let width = 300.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speed Up Typing")
                .font(.headline)
            Picker("Speed", selection: $speed) {
                ForEach(TypingSpeed.speeds, id: \.self) { value in
                    Text(verbatim: TimelineFormat.multiplier(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Speed"))
            result
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { model.isAskingTypingSpeed = false }
                    .keyboardShortcut(.cancelAction)
                Button("Speed Up") {
                    model.isAskingTypingSpeed = false
                    model.speedUpTyping(speed: speed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled((summary?.count ?? 0) == 0)
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .task(id: speed) { summary = await model.typingSpeedSummary(speed: speed) }
    }

    @ViewBuilder
    private var result: some View {
        if let summary {
            Text(verbatim: Self.sentence(summary))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(summary.count == 0 ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
        }
    }

    /// "Se aceleran 5 tramos: 1:23 → 0:28", or that there is none.
    static func sentence(_ summary: TypingSpeed.Summary) -> String {
        let (before, after) = (clock(summary.before), clock(summary.after))
        switch summary.count {
        case 0: return String(localized: "No typing of 2 seconds or more.")
        case 1: return String(localized: "One stretch sped up: \(before) → \(after)")
        default: return String(localized: "\(summary.count) stretches sped up: \(before) → \(after)")
        }
    }

    /// `nanoseconds` as minutes and seconds: "1:23".
    static func clock(_ nanoseconds: Int64) -> String {
        let seconds = Int((Double(nanoseconds) / 1e9).rounded())
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

extension View {
    /// The popover of Speed Up Typing, over this view.
    func typingSpeedPopover(_ model: EditorModel) -> some View {
        popover(
            isPresented: Binding(get: { model.isAskingTypingSpeed }, set: { model.isAskingTypingSpeed = $0 }),
            arrowEdge: .bottom
        ) {
            TypingSpeedPopover(model: model)
        }
    }
}
