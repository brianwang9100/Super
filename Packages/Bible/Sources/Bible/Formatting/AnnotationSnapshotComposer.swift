import Foundation

/// Renders an annotation record into the markdown snapshot block that
/// `RecordReference.snapshot` carries to the chat composer.
///
/// The LLM (Large Language Model) sees this block verbatim when the user
/// taps "Add to chat" on the annotation sheet. The format is plain
/// markdown: an H2 naming the target, then the stored summary as-is (the
/// summary is already markdown; its citations stay plain text here — the
/// tappable-link rendering is purely a UI affordance inside the sheet and
/// has no place in the chat context).
///
/// A caseless namespace: composition is a pure function with no state.
public enum AnnotationSnapshotComposer {
    /// Format:
    /// ```
    /// ## {citation} — annotation
    ///
    /// {summary}
    /// ```
    /// The trailing newline keeps the block visually separated from
    /// surrounding composer content the user may type around it.
    public static func compose(annotation: BibleAnnotationRecord, citation: String) -> String {
        "## \(citation) — annotation\n\n\(annotation.summary)\n"
    }
}
