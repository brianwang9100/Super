import Foundation

/// Holds only the current utterance; completed phrases are drained exactly once.
/// Recognition revisions never have access to phrases already emitted to a consumer.
struct DictationTranscriptAccumulator: Sendable {
    private(set) var partialTranscript = ""

    /// Empty callbacks are not retractions of speech already recognized.
    mutating func ingestPartial(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { partialTranscript = text }
    }

    /// Final text may refine the current phrase. An empty final uses its last preview.
    mutating func commitCurrentUtterance(_ text: String = "") -> String {
        ingestPartial(text)
        let committed = partialTranscript
        partialTranscript = ""
        return committed
    }
}
