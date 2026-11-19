// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ImageAnalysis
import ProjectFormat
import SwiftUI

/// The findings of the search of sensitive data (phase 2 design §7.2): by kind, each with its box (all checked but what the
/// document already hides), its text masked as the cache keeps it and where the output shows it; the known limit of the
/// search; and "Blur N", which adds the checked ones in one step (`privacy.auto`).
struct SensitiveFindingsSheet: View {
    let findings: [PrivacyFinding]
    @State var rules: FindingsSheetRules
    let close: () -> Void
    let blur: ([PrivacyBlock]) -> Void

    init(findings: [PrivacyFinding], rules: FindingsSheetRules, close: @escaping () -> Void, blur: @escaping ([PrivacyBlock]) -> Void) {
        self.findings = findings
        _rules = State(initialValue: rules)
        self.close = close
        self.blur = blur
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(rules.groups, id: \.origin) { group in
                        section(group)
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 160, maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
                .padding(20)
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.16)))
                .accessibilityHidden(true)
            Text("Sensitive Data Found")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func section(_ group: FindingsSheetRules.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(Self.groupName(group.origin), systemImage: Self.symbol(group.origin))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(group.indices.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(group.indices.enumerated()), id: \.element) { position, index in
                    if position > 0 { Divider().padding(.leading, 34) }
                    row(index)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private func row(_ index: Int) -> some View {
        let finding = findings[index]
        let text = finding.masked.isEmpty ? String(localized: "Face") : finding.masked
        let time = rules.output(of: index).map { "\(Timecode.duration(Double($0.lowerBound) / 1e9))–\(Timecode.duration(Double($0.upperBound) / 1e9))" } ?? ""
        let hidden = rules.alreadyHidden.contains(index)
        return Toggle(isOn: Binding(get: { rules.isChecked(index) }, set: { _ in rules.toggle(index) })) {
            HStack(spacing: 8) {
                Text(verbatim: text)
                    .font(finding.masked.isEmpty ? .body : .body.monospaced())
                    .lineLimit(1)
                Spacer(minLength: 8)
                if hidden {
                    Text("Already Blurred")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: time)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel(Text(verbatim: hidden ? "\(text), \(time), \(String(localized: "Already Blurred"))" : "\(text), \(time)"))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Text that scrolls fast between two samples can show for an instant. Check before publishing.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button {
                    blur(rules.chosen)
                } label: {
                    Text("Blur \(rules.addCount)")
                        .frame(minWidth: 96)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rules.addCount == 0)
            }
            .controlSize(.large)
        }
    }

    /// "Correos", "Teléfonos", "Tarjetas", "Claves y tokens", "Caras".
    static func groupName(_ origin: PrivacyOrigin) -> String {
        switch origin {
        case .email: String(localized: "Emails")
        case .phone: String(localized: "Phones")
        case .card: String(localized: "Cards", comment: "A group of the findings of the sensitive data search: credit card numbers")
        case .secret: String(localized: "Keys and Tokens")
        case .face: String(localized: "Faces")
        case .manual: String(localized: "Blur")
        }
    }

    /// "Correo", "Teléfono", "Tarjeta", "Clave o token", "Cara": what a block of the search hides.
    static func kindName(_ origin: PrivacyOrigin) -> String {
        switch origin {
        case .email: String(localized: "Email", comment: "What a privacy block made by the sensitive data search hides: an email address")
        case .phone: String(localized: "Phone", comment: "What a privacy block made by the sensitive data search hides: a phone number")
        case .card: String(localized: "Card", comment: "What a privacy block made by the sensitive data search hides: a credit card number")
        case .secret: String(localized: "Key or Token")
        case .face: String(localized: "Face")
        case .manual: String(localized: "Blur")
        }
    }

    static func symbol(_ origin: PrivacyOrigin) -> String {
        switch origin {
        case .email: "envelope"
        case .phone: "phone"
        case .card: "creditcard"
        case .secret: "key"
        case .face: "face.smiling"
        case .manual: "eye.slash"
        }
    }
}
