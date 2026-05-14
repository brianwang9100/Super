import Foundation

/// Merges multiple recognizer-emitted utterances within a single voice
/// recording session into a single rendered transcript. Each "utterance"
/// is the text the on-device `SFSpeechRecognizer` (SFSpeech = Apple's
/// Speech-recognition framework) finalized between two natural pauses;
/// the recognizer auto-endpoints after ~600 ms–1.5 s of silence and the
/// service commits the utterance here, then transparently spins up a
/// fresh recognition task whose interim partials feed back through
/// `ingestPartial`.
///
/// Pure value type — no I/O, no async, no shared state — so the join/
/// trim/separator rules can be exhaustively unit-tested without standing
/// up a recognizer or audio engine.
struct DictationTranscriptAccumulator: Sendable {
    /// Utterances the recognizer has finalized this session, in the
    /// order they were spoken. Whitespace-trimmed at commit time;
    /// empty entries are never stored.
    private var committed: [String] = []

    /// The in-flight partial for the *current* recognition task — the
    /// part the recognizer is still revising. Whitespace-trimmed on
    /// every `ingestPartial`. Cleared on `commitCurrentUtterance` so the
    /// committed text doesn't appear twice (once committed, once still
    /// in-flight).
    private var currentPartial: String = ""

    /// Overwrite the in-flight partial with the latest hypothesis from
    /// the active recognition task. Trims whitespace; an empty/whitespace
    /// input collapses to "" (which renders as nothing).
    mutating func ingestPartial(_ text: String) {
        currentPartial = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Move a finalized utterance from the active task into the
    /// committed buffer. Trims whitespace; empty/whitespace-only input is
    /// a no-op so a stray `isFinal` callback with no recognized speech
    /// doesn't introduce a phantom separator. Always clears
    /// `currentPartial` — once the recognizer finalizes, the same text
    /// should not also linger as an in-flight partial.
    mutating func commitCurrentUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            committed.append(trimmed)
        }
        currentPartial = ""
    }

    /// Single-space-joined concatenation of every committed utterance
    /// followed by the in-flight partial. No leading or trailing space.
    var renderedTranscript: String {
        let parts = currentPartial.isEmpty ? committed : committed + [currentPartial]
        return parts.joined(separator: " ")
    }
}
