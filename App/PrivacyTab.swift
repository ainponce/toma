// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ImageAnalysis
import ProjectFormat
import ProjectJobs
import SwiftUI

/// The panel's Privacy tab (phase 2 design §7.1 and §7.2): above, the card of the selected block if one is (its effect,
/// its strength or color, where it is, Delete Blur); then Add Blur, Find Sensitive Data with its progress, its result or
/// why it could not; and below, the blocks, each one choosing it and taking the playhead to it.
struct PrivacyTab: View {
    let model: EditorModel

    @State private var search = SensitiveSearch()

    var body: some View {
        if let document = model.document {
            VStack(alignment: .leading, spacing: 18) {
                if case let .privacyBlocks(ids)? = model.selection, ids.count == 1,
                    let block = document.privacy.blocks.first(where: { ids.contains($0.id) })
                {
                    SelectedBlurCard(model: model, block: block, output: PrivacyCommands.outputRange(of: block, in: document))
                    Divider()
                }
                PanelSection {
                    Button {
                        model.addBlur()
                    } label: {
                        Label("Add Blur", systemImage: "eye.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                SensitiveSearchSection(model: model, search: search)
                Divider()
                PrivacyBlockList(model: model, document: document)
            }
            .task { await search.follow(model) }
        }
    }
}

/// "Find Sensitive Data" and where it is: the button with what it looks for; while it waits or runs, its progress and
/// Cancel; once done, See Findings (N) or that nothing was found; or why it could not.
private struct SensitiveSearchSection: View {
    let model: EditorModel
    let search: SensitiveSearch

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelSection {
            switch search.phase {
            case let .searching(progress):
                running(progress)
            default:
                Button {
                    if model.findSensitiveData() { search.started() }
                } label: {
                    Label("Find Sensitive Data", systemImage: "text.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!search.canRecognize)
                outcome
            }
        }
        .animation(.panel(Motion.selector, reduceMotion: reduceMotion), value: search.phase)
    }

    private func running(_ progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    if let progress {
                        Text("Searching… \(Self.percent(progress))", comment: "The sensitive data search runs: how far, as 42 %")
                            .monospacedDigit()
                    } else {
                        Text("Waiting…", comment: "The sensitive data search waits for another analysis of the project to end")
                    }
                } icon: {
                    Image(systemName: "text.viewfinder")
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelSensitiveSearch() }
                    .controlSize(.small)
            }
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel(Text("Find Sensitive Data"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22)))
    }

    @ViewBuilder
    private var outcome: some View {
        if !search.canRecognize {
            note(Self.reason(.notOnThisMac), symbol: "exclamationmark.triangle", warning: true)
        } else {
            switch search.phase {
            case let .found(findings) where !findings.isEmpty:
                Button {
                    model.showSensitiveFindings(findings)
                } label: {
                    Label("See Findings (\(findings.count))", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            case .found:
                note(String(localized: "No sensitive data found."), symbol: "checkmark.shield", warning: false)
            case let .failed(problem), let .unavailable(problem):
                note(Self.reason(problem), symbol: "exclamationmark.triangle", warning: true)
            case .idle, .searching:
                Text("Looks for emails, phones, cards, keys and faces on the whole recording's screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func note(_ text: String, symbol: String, warning: Bool) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// "42 %".
    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down))) %"
    }

    /// Why the search found nothing, in words.
    static func reason(_ problem: JobProblem) -> String {
        switch problem {
        case .notOnThisMac, .needsMacOS26, .modelNotInstalled:
            String(localized: "Text recognition isn't available on this Mac.")
        case .sourceUnreadable:
            String(localized: "Part of the recording couldn't be read.")
        case .noSpace:
            String(localized: "The search couldn't finish: the disk is full.")
        case .failed:
            String(localized: "The search couldn't finish.")
        }
    }
}

/// The selected block (design §7.1): what it does (Blur, Pixelate, Fill), how much (the strength of Blur and Pixelate, a
/// drag a gesture) or with which colour (Fill), where the output shows it and Delete Blur. A block of the search says what
/// it hides.
private struct SelectedBlurCard: View {
    let model: EditorModel
    let block: PrivacyBlock
    let output: Range<Int64>?

    /// Black, white and grey; any other from the colour panel.
    private static let swatches = [RGBA(0, 0, 0, 1), RGBA(1, 1, 1, 1), RGBA(0.5, 0.5, 0.5, 1)]

    var body: some View {
        PanelSection("Selected Blur") {
            if block.origin != .manual {
                Label {
                    Text(verbatim: "\(String(localized: "Automatic")) · \(SensitiveFindingsSheet.kindName(block.origin))")
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Text("Effect")
                .accessibilityHidden(true)
            PrivacyEffectTiles(selected: block.effect) { model.setPrivacyEffect($0, id: block.id) }
            switch block.effect {
            case .blur, .pixelate:
                PanelSlider(title: "Strength", model: model, value: Int((block.strength * 100).rounded())) {
                    model.setPrivacyStrength(percent: $0, id: block.id)
                }
            case .fill:
                colors
            }
            if let output {
                Text("From \(Self.time(output.lowerBound)) to \(Self.time(output.upperBound))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Delete Blur", role: .destructive) { model.deletePrivacyBlock(block.id) }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { index, swatch in
                    Button {
                        model.setPrivacyColor(swatch, id: block.id)
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay {
                                if block.color == swatch { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(block.color == swatch ? .isSelected : [])
                    .accessibilityLabel(Text(verbatim: Self.swatchName(index)))
                }
                Spacer(minLength: 8)
                ColorPicker(
                    "Color", selection: Binding(get: { block.color.color }, set: { model.setPrivacyColor(RGBA($0), id: block.id) }),
                    supportsOpacity: false
                )
                .labelsHidden()
            }
        }
    }

    private static func swatchName(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "Black")
        case 1: String(localized: "White")
        default: String(localized: "Gray")
        }
    }

    static func time(_ τ: Int64) -> String {
        Timecode.duration(Double(τ) / 1e9)
    }
}

/// The three effects as tiles with their symbols (plan 2c decision 21): choosing one moves the ring by `Motion.selector`
/// (a fade with Reduce Motion). VoiceOver reads "Effect, Pixelate, 2 of 3".
private struct PrivacyEffectTiles: View {
    let selected: PrivacyEffect
    let choose: (PrivacyEffect) -> Void

    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(PrivacyEffect.allCases.enumerated()), id: \.element) { index, effect in
                tile(effect, index: index)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tile(_ effect: PrivacyEffect, index: Int) -> some View {
        let name = TimelinePrivacyItems.name(effect)
        let isSelected = effect == selected
        return Button {
            guard !isSelected else { return }
            withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) { choose(effect) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: TimelinePrivacyItems.symbol(effect))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(height: 18)
                Text(verbatim: name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .matchedGeometryEffect(id: "ring", in: ring)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: name))
        .accessibilityLabel(
            Text(verbatim: String(format: String(localized: "Effect, %1$@, %2$d of %3$d"), name, index + 1, PrivacyEffect.allCases.count)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The blocks the output shows, by their start: each with its effect, whether the search made it, and when; the one
/// selected in the accent colour. Choosing one selects it and takes the playhead to its first frame. Without any, what
/// the tab is for.
private struct PrivacyBlockList: View {
    let model: EditorModel
    let document: EditDocument

    var body: some View {
        let shown = document.privacy.blocks.compactMap { block in
            PrivacyCommands.outputRange(of: block, in: document).map { (block: block, output: $0) }
        }.sorted { ($0.output.lowerBound, $0.output.upperBound) < ($1.output.lowerBound, $1.output.upperBound) }
        PanelSection("Blurs") {
            if shown.isEmpty {
                empty
            } else {
                VStack(spacing: 2) {
                    ForEach(shown, id: \.block.id) { item in
                        row(item.block, output: item.output)
                    }
                }
            }
        }
    }

    private var selected: Set<String> {
        if case let .privacyBlocks(ids)? = model.selection { ids } else { [] }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Nothing is hidden yet")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Add a blur or find sensitive data to hide what shouldn't be seen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ block: PrivacyBlock, output: Range<Int64>) -> some View {
        let isSelected = selected.contains(block.id)
        let automatic = block.origin != .manual
        let name = TimelinePrivacyItems.name(block.effect)
        let detail = automatic ? SensitiveFindingsSheet.kindName(block.origin) : nil
        return Button {
            model.selectPrivacyBlock(block.id, showingIt: true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: automatic ? "sparkles" : TimelinePrivacyItems.symbol(block.effect))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name)
                        .lineLimit(1)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(SelectedBlurCard.time(output.lowerBound))–\(SelectedBlurCard.time(output.upperBound))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PrivacyRowStyle())
        .accessibilityLabel(
            Text(verbatim: TimelinePrivacyItems.accessibilityLabel(.init(effect: block.effect, automatic: automatic, rank: 0), output: output)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A row of the list: a wash while the mouse is over it or it is pressed.
private struct PrivacyRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrivacyRowLabel(configuration: configuration)
    }
}

private struct PrivacyRowLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background {
                if hovering || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05))
                }
            }
            .onHover { hovering = $0 }
            .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: hovering)
    }
}
