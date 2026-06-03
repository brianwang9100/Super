/// A seam for single-shot Bible-annotation generation: one call runs one LLM
/// turn against one scripture target (a verse range, chapter, or book) and
/// returns a `BibleAnnotateOutcome`.
///
/// It lives in Core so a generator can be reached by code that can't import the
/// package that owns it. Today the only implementer is Chat's
/// `BibleAnnotateDispatcher`; the Bible-package bulk-annotation runner (a
/// follow-on) drives generation through this protocol — Bible can't import Chat,
/// so the composition root injects the dispatcher as a `BibleAnnotateGenerating`.
///
/// Implementations never throw — every failure is carried in
/// `BibleAnnotateOutcome.failure` with a classification the caller acts on.
public protocol BibleAnnotateGenerating: Sendable {
    func generate(reference: RecordReference) async -> BibleAnnotateOutcome
}
