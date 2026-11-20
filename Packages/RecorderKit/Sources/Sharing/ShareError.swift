// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why sharing failed (plan 5a). None of its cases carries a header, a URL's query, a body or the secret: only S3's error
/// code, an HTTP status or a `URLError` code, so an error can be shown or logged as it is.
public enum ShareError: Error, Equatable, Sendable {
    /// What Settings ▸ Share holds cannot make a configuration.
    case notConfigured(ShareConfigurationProblem)
    /// The storage refused the credentials: `InvalidAccessKeyId`, `SignatureDoesNotMatch`, `AccessDenied`… (or the HTTP
    /// status, as text, when a 401 or 403 came without a code).
    case authentication(code: String)
    /// The bucket does not exist at this endpoint.
    case noSuchBucket
    /// Any other answer that is not a success; `code` is S3's `<Code>` when the body had one. A status 200 with a code is a
    /// `CompleteMultipartUpload` that failed after answering.
    case server(status: Int, code: String?)
    /// The request never got an answer.
    case network(URLError.Code)
    /// The storage says the Mac's clock is off, still after correcting it once with the server's.
    case clockSkew
    /// "Test Connection": the public base URL did not give back what was uploaded.
    case publicURLNotServing(status: Int)
    /// A share made on another storage than the one Settings ▸ Share holds now.
    case otherStorage
    /// The person cancelled; whatever was uploaded is being removed.
    case cancelled
    /// The package's `shares.json` cannot be read, so it is never written.
    case historyUnreadable
    /// The link was uploaded but the package's `shares.json` could not record it (it became unreadable, it is full, the
    /// disk failed), so its three objects were removed from the storage: nothing stays shared that the project cannot
    /// list and delete.
    case notSaved
}
