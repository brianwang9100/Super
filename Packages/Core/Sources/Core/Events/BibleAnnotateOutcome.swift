/// Rich outcome of a single-shot `bible.annotate` generation, returned by a
/// `BibleAnnotateGenerating`.
///
/// Unlike `BibleAnnotateResult` — the bus/UI-facing type the spark button reads,
/// which carries only a human-facing failure `message` — a failure here also
/// carries a `BibleAnnotateFailure` classification so a programmatic caller (the
/// bulk-annotation runner) can decide whether to retry the unit or halt the
/// whole run. Flatten back to `BibleAnnotateResult` with `asResult` for the bus.
public enum BibleAnnotateOutcome: Sendable, Equatable {
    /// The model called `bible.annotate` and the tool wrote the listed number
    /// of rows. Zero is a valid success (the tool ran but every entry collided
    /// with an existing row) — mirrors `BibleAnnotateResult.success`.
    case success(annotationCount: Int)

    /// The dispatch produced no annotations. `message` is the same short,
    /// human-readable reason `BibleAnnotateResult.failure` carries;
    /// `classification` tells a bulk caller how to react.
    case failure(message: String, classification: BibleAnnotateFailure)

    /// Flatten to the bus/UI-facing `BibleAnnotateResult`, dropping the
    /// classification (the spark-button flow only needs the message). Keeps the
    /// `bibleAnnotateCompleted` event payload byte-identical to before.
    public var asResult: BibleAnnotateResult {
        switch self {
        case .success(let annotationCount):
            .success(annotationCount: annotationCount)
        case .failure(let message, _):
            .failure(message: message)
        }
    }
}
