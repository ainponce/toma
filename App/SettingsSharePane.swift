// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Sharing
import SwiftUI

/// Settings ▸ Share (plan 5a, Task S4; design §8.1): the service and its endpoint, region, bucket and prefix; the Access
/// Key ID and the secret key, which goes to the Keychain and is never shown; the public base URL and how long a signed
/// link lasts; and "Test Connection". What is wrong with a field is said under it; what is missing, once, by "Test
/// Connection".
struct SettingsSharePane: View {
    @State private var model = SettingsShareModel.make()
    @FocusState private var focus: SettingsShareModel.Field?

    var body: some View {
        Section {
            Picker(selection: Binding(get: { model.preferences.provider }, set: { model.setProvider($0) })) {
                ForEach(ShareProvider.allCases, id: \.self) { provider in
                    Text(verbatim: Self.name(provider)).tag(provider)
                }
            } label: {
                Text("Service", comment: "Settings ▸ Share: the storage service")
            }
            field(.endpoint, text: Binding(get: { model.preferences.endpoint }, set: { model.setEndpoint($0) }),
                  prompt: model.preferences.provider.endpointTemplate) {
                Text("Endpoint", comment: "Settings ▸ Share: the storage's address")
            }
            field(.region, text: Binding(get: { model.preferences.region }, set: { model.setRegion($0) }),
                  prompt: model.preferences.provider.defaultRegion) {
                Text("Region", comment: "Settings ▸ Share: the storage's region")
            }
            field(.bucket, text: Binding(get: { model.preferences.bucket }, set: { model.setBucket($0) }), prompt: "") {
                Text("Bucket", comment: "Settings ▸ Share: the storage's bucket")
            }
            field(.prefix, text: Binding(get: { model.preferences.prefix }, set: { model.setPrefix($0) }), prompt: "toma/") {
                Text("Prefix", comment: "Settings ▸ Share: what the uploaded files' names start with")
            }
        }
        Section {
            field(
                .accessKey, text: Binding(get: { model.preferences.accessKeyID }, set: { model.setAccessKeyID($0) }), prompt: ""
            ) {
                Text(verbatim: "Access Key ID")
            }
            .onSubmit { model.commitAccessKey() }
            secretRow
        } footer: {
            Footer(
                Text(
                    "The secret key is saved in the macOS Keychain, never in a file.",
                    comment: "Under the secret key in Settings ▸ Share"))
        }
        Section {
            field(
                .publicURL, text: Binding(get: { model.preferences.publicBaseURL }, set: { model.setPublicBaseURL($0) }),
                prompt: "https://videos.example.com"
            ) {
                Text("Public Base URL (Optional)", comment: "Settings ▸ Share: the public address of the bucket")
            }
            Picker(selection: Binding(get: { model.preferences.linkDays }, set: { model.setLinkDays($0) })) {
                ForEach(1...7, id: \.self) { days in
                    Text(Self.days(days)).tag(days)
                }
            } label: {
                Text("Link Expiration", comment: "Settings ▸ Share: how long a signed link works")
            }
            .disabled(model.hasPublicURL)
        } footer: {
            Footer(
                model.hasPublicURL
                    ? Text("With a public URL, the link never expires.", comment: "Under the link's expiration in Settings ▸ Share, with a public URL")
                    : Text(
                        "Without a public URL, the link is signed and stops working after this time.",
                        comment: "Under the link's expiration in Settings ▸ Share, without a public URL"))
        }
        Section {
            testRow
        }
        .onAppear { model.load() }
        .onDisappear {
            model.commitSecret()
            model.commitAccessKey()
        }
        .onChange(of: focus) { old, _ in
            // Leaving the Access Key ID or the secret key confirms it.
            if old == .accessKey { model.commitAccessKey() }
            if old == .secret { model.commitSecret() }
        }
    }

    /// The secret key: a secure field whose placeholder says when the Keychain has it (never the key itself), and
    /// "Delete Key".
    @ViewBuilder
    private var secretRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                SecureField(
                    text: $model.secretDraft,
                    prompt: model.hasSecret
                        ? Text("Saved in the Keychain", comment: "Settings ▸ Share: the secret key's field when the Keychain has it")
                        : nil
                ) {
                    Text("Secret Key", comment: "Settings ▸ Share: the secret access key")
                }
                .labelsHidden()
                .frame(minWidth: 180, maxWidth: .infinity)
                .focused($focus, equals: .secret)
                .onSubmit { model.commitSecret() }
                if model.hasSecret {
                    Button {
                        model.deleteSecret()
                    } label: {
                        Text("Delete Key", comment: "Settings ▸ Share: deletes the secret key from the Keychain")
                    }
                    .fixedSize()
                }
            }
        } label: {
            Text("Secret Key", comment: "Settings ▸ Share: the secret access key")
        }
        if let problem = model.secretProblem {
            Self.problem(problem)
        }
    }

    /// "Test Connection" and how it went; what is missing for it, before.
    private var testRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    model.testConnection()
                } label: {
                    Text("Test Connection", comment: "Settings ▸ Share: uploads and deletes a small file")
                }
                .disabled(!model.problems.isEmpty || model.test == .testing)
                if model.test == .testing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            switch model.test {
            case .succeeded:
                Label {
                    Text(
                        "Connected: a test file was uploaded and deleted.",
                        comment: "Settings ▸ Share: Test Connection went well")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Self.problem(reason)
            case .idle, .testing:
                if let missing = model.missing {
                    Text(verbatim: ShareTexts.describe(missing))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A text field of `field`, and what is wrong with it in the row under it.
    @ViewBuilder
    private func field(
        _ field: SettingsShareModel.Field, text: Binding<String>, prompt: String, @ViewBuilder label: () -> Text
    ) -> some View {
        TextField(text: text, prompt: prompt.isEmpty ? nil : Text(verbatim: prompt), label: label)
            .focused($focus, equals: field)
            .autocorrectionDisabled()
        if let problem = model.problem(of: field) {
            Self.problem(ShareTexts.describe(problem))
        }
    }

    private static func problem(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The service's name as its maker writes it; "Other" in the app's language.
    static func name(_ provider: ShareProvider) -> String {
        switch provider {
        case .r2: "Cloudflare R2"
        case .s3: "Amazon S3"
        case .b2: "Backblaze B2"
        case .minio: "MinIO"
        case .other: String(localized: "Other S3-Compatible", comment: "Settings ▸ Share: a storage service that speaks S3's API")
        }
    }

    static func days(_ days: Int) -> String {
        days == 1
            ? String(localized: "1 day", comment: "Settings ▸ Share: a signed link lasts one day")
            : String(format: String(localized: "%lld days", comment: "Settings ▸ Share: a signed link lasts 2 to 7 days"), days)
    }
}

/// Under a section of Settings ▸ Share: as the other panes' footers.
private struct Footer: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
