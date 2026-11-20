// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Sharing

/// Share's words (plan 5a, Task S4): why sharing, deleting or "Test Connection" failed (`ShareError`, the Keychain's
/// `SecretStoreError`, an export's error), what keeps Settings ▸ Share from making a configuration
/// (`ShareConfigurationProblem`), and what is said of a link (design §8.4). None of them ever carries the secret.
enum ShareTexts {
    /// Why sharing, deleting or "Test Connection" failed, in words.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ShareError: describe(error)
        case let error as SecretStoreError: describe(error)
        default:
            String(
                format: String(localized: "Couldn't export the video: %@", comment: "Share failed while exporting the video, and why"),
                userFacingDescription(of: error))
        }
    }

    static func describe(_ error: ShareError) -> String {
        switch error {
        case .notConfigured(let problem):
            problem == .missingSecret
                ? String(localized: "Settings ▸ Share has no secret key. Enter it there.", comment: "Share: the Keychain has no secret key for the Access Key ID")
                : String(
                    format: String(localized: "Settings ▸ Share isn't complete: %@", comment: "Share: what Settings ▸ Share is missing, a sentence after the colon"),
                    describe(problem))
        case .authentication(let code):
            String(
                format: String(
                    localized: "The storage didn't accept the keys (%@). Check the Access Key ID and the secret key.",
                    comment: "Share: the storage refused the credentials; the storage's error code in parentheses"),
                code)
        case .noSuchBucket:
            String(localized: "The bucket doesn't exist at this endpoint.", comment: "Share: the storage has no bucket of that name")
        case .server(let status, let code):
            String(
                format: String(localized: "The storage answered with an error (%@).", comment: "Share: the storage's error code or HTTP status in parentheses"),
                code ?? "HTTP \(status)")
        case .network(let code):
            describe(code)
        case .clockSkew:
            String(
                localized: "The storage says this Mac's clock is wrong. Check the date and time in System Settings.",
                comment: "Share: the storage refused the request's time")
        case .publicURLNotServing(let status):
            String(
                format: String(
                    localized: "The public URL didn't give back the test file (HTTP %lld). Check that the bucket is public at that address.",
                    comment: "Test Connection: the public base URL did not serve the uploaded file"),
                status)
        case .otherStorage:
            String(
                localized: "This link is on another storage than the one in Settings ▸ Share, so it can't be deleted from here.",
                comment: "Delete from Storage: the link was shared to another endpoint or bucket")
        case .cancelled:
            String(localized: "The operation was canceled.")
        case .historyUnreadable:
            String(
                localized: "The project's list of links (shares.json) can't be read, so nothing was shared.",
                comment: "Share: the project's shares.json is unreadable; “shares.json” stays as it is")
        case .notSaved:
            String(
                localized: "The link couldn't be recorded in the project, so it was removed from the storage.",
                comment: "Share: shares.json could not be written after the upload, so the uploaded objects were deleted")
        case let .notSavedNorRemoved(bucket, folder):
            String(
                format: String(
                    localized: "The link couldn't be recorded in the project, and its files couldn't be removed from the storage: they may still be online. Delete the folder “%1$@” of the bucket “%2$@” in your storage's console.",
                    comment: "Share: shares.json could not be written after the upload and deleting the uploaded objects failed too; the folder and the bucket's name"),
                folder, bucket)
        }
    }

    static func describe(_ error: SecretStoreError) -> String {
        switch error {
        case .keychain(let status):
            String(
                format: String(localized: "The Keychain couldn't give the secret key (error %lld).", comment: "Share: reading or saving the secret key in the Keychain failed"),
                Int(status))
        case .notText:
            String(
                localized: "What the Keychain has for this key isn't text. Enter the secret key again in Settings ▸ Share.",
                comment: "Share: the Keychain item is not UTF-8 text")
        }
    }

    /// A request that never got an answer.
    static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            String(localized: "This Mac isn't connected to the internet.", comment: "Share: no network")
        case .cannotFindHost, .dnsLookupFailed:
            String(localized: "The endpoint's server wasn't found. Check the endpoint.", comment: "Share: the endpoint's host does not resolve")
        case .timedOut:
            String(localized: "The storage took too long to answer.", comment: "Share: a request timed out")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            String(localized: "The storage's secure connection isn't valid.", comment: "Share: TLS failed")
        default:
            String(
                format: String(localized: "Couldn't connect to the storage (error %lld).", comment: "Share: a network error, its URLError code"),
                code.rawValue)
        }
    }

    /// What keeps Settings ▸ Share from making a configuration, shown under its field.
    static func describe(_ problem: ShareConfigurationProblem) -> String {
        switch problem {
        case .missingEndpoint:
            String(localized: "Enter the service's endpoint.", comment: "Settings ▸ Share: the endpoint is empty")
        case .invalidEndpoint:
            String(localized: "Enter an address like https://host, without a path.", comment: "Settings ▸ Share: the endpoint is not a URL of a host")
        case .insecureEndpoint:
            String(
                localized: "Use https://. Only this Mac (localhost) can use http://.",
                comment: "Settings ▸ Share: an http:// endpoint that is not localhost")
        case .missingBucket:
            String(localized: "Enter the bucket.", comment: "Settings ▸ Share: the bucket is empty")
        case .invalidBucket:
            String(
                localized: "A bucket's name has only letters, numbers, periods, hyphens and underscores.",
                comment: "Settings ▸ Share: the bucket's name has characters a bucket cannot have")
        case .invalidPrefix:
            String(localized: "The prefix can't have “.” or “..” parts.", comment: "Settings ▸ Share: the prefix has a . or .. segment")
        case .missingAccessKey:
            String(localized: "Enter the Access Key ID.", comment: "Settings ▸ Share: the Access Key ID is empty")
        case .invalidAccessKey:
            String(
                localized: "An Access Key ID has no spaces or / , = ;",
                comment: "Settings ▸ Share: the Access Key ID has a character that breaks the signature")
        case .missingSecret:
            String(localized: "Enter the secret key.", comment: "Settings ▸ Share: the Keychain has no secret key")
        case .invalidPublicURL:
            String(localized: "Enter an address like https://host/path.", comment: "Settings ▸ Share: the public base URL is not a URL")
        case .insecurePublicURL:
            String(localized: "Use https://.", comment: "Settings ▸ Share: an http:// public URL that is not localhost")
        case .invalidRegion:
            String(
                localized: "A region has only lowercase letters, numbers and hyphens.",
                comment: "Settings ▸ Share: the region has characters a region cannot have")
        }
    }

    /// A link in the list: "Public", "Expires <date and time>" or "Expired".
    static func status(_ note: ShareRules.LinkNote) -> String {
        switch note {
        case .permanent:
            String(localized: "Public", comment: "A shared link that never expires")
        case .expires(let date):
            String(
                format: String(localized: "Expires %@", comment: "A shared link: when it stops working"),
                date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        case .expired:
            String(localized: "Expired", comment: "A shared link that no longer works")
        }
    }

    /// What is said once a link is copied (design §8.4): whether it is public, or when it expires.
    static func copied(_ note: ShareRules.LinkNote) -> String {
        switch note {
        case .permanent:
            String(
                localized: "Link copied. It's public: anyone with the link can watch it.",
                comment: "After copying a public shared link")
        case .expires(let date):
            String(
                format: String(
                    localized: "Link copied. Until %@, anyone with the link can watch it.",
                    comment: "After copying a signed shared link: when it stops working"),
                date.formatted(date: .long, time: .shortened))
        case .expired(let date):
            String(
                format: String(localized: "Link copied. It expired on %@ and no longer works.", comment: "After copying a shared link that expired"),
                date.formatted(date: .long, time: .shortened))
        }
    }

    /// How long the link of a share made now lasts: with a public URL it never expires; signed, `days` days.
    static func lifetime(of preferences: SharePreferences) -> String {
        if !preferences.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "The link is public and never expires.", comment: "Share, before sharing: a public link")
        }
        let days = min(max(preferences.linkDays, 1), 7)
        return days == 1
            ? String(localized: "The link expires in a day.", comment: "Share, before sharing: a signed link of one day")
            : String(
                format: String(localized: "The link expires in %lld days.", comment: "Share, before sharing: a signed link of 2 to 7 days"), days)
    }
}
