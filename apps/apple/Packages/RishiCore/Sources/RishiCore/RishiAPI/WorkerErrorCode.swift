import Foundation

/// Centralised, named worker error-envelope `code` strings.
///
/// The Rishi worker returns structured 4xx errors as an `ErrorEnvelope`
/// whose `code` is a stable contract string. `WorkerClient.send` surfaces it
/// as `RishiError.network(code:message:)`. These constants document that
/// cross-package contract in ONE place so consumers (e.g. the voice layer's
/// `KeyFetchFailure.classify`) key off a named symbol instead of an
/// undocumented bare literal that silently breaks if the worker's string
/// drifts.
public enum WorkerErrorCode {
    /// HTTP 402 — the user lacks an active Pro subscription. Worker body:
    /// `{ "error": { "code": "BILLING_INACTIVE", ... } }`. A paywall signal,
    /// NOT a transient/service failure — consumers must surface "subscription
    /// required" rather than invite retry storms against a 402.
    public static let billingInactive = "BILLING_INACTIVE"
}
