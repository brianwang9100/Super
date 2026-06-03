/// How a `BibleAnnotateOutcome.failure` should be treated by a bulk run.
///
/// Maps onto the run-level circuit breaker: a fatal failure halts the whole run
/// (stamping the matching `BulkRunHaltReason`) to protect the user's wallet,
/// while a retryable failure is retried per unit — persistent retryables trip
/// the consecutive-failure breaker instead.
public enum BibleAnnotateFailure: Sendable, Equatable {
    /// Transient — network blip, decode flake, an unsupported/odd provider
    /// error, or a model that simply didn't call the tool. Retry the unit.
    case retryable
    /// Fatal credentials/config error (invalid key, no active provider). Halt
    /// the run (`BulkRunHaltReason.auth`) — retrying can't fix it.
    case fatalAuth
    /// Fatal quota / rate-limit error. Halt the run (`BulkRunHaltReason.quota`)
    /// rather than burn through more requests.
    case fatalQuota
}
