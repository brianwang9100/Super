import Foundation

/// Renders one or more annotation records into the markdown snapshot block
/// that `RecordReference.snapshot` carries to the chat composer.
///
/// The LLM (Large Language Model) sees this block verbatim when the user
/// taps "Add to chat" or "Add all to chat" on a popover card. The format
/// is intentionally plain markdown — no embedded links, no per-card kebab
/// affordances, no model-id footer. Reference-kind cards render as their
/// citation string (`"John 1:14"`) so the model sees a clean
/// natural-language reference; the citation-as-link rendering is purely a
/// UI affordance inside the popover and has no place in the chat context.
///
/// A caseless namespace: composition is a pure function with no state.
public enum AnnotationSnapshotComposer {
    /// Single-card snapshot.
    ///
    /// Format:
    /// ```
    /// ## {title}
    ///
    /// {body}
    /// ```
    /// The trailing newline keeps the block visually separated from
    /// surrounding composer content the user may type around it.
    public static func compose(annotation: BibleAnnotationRecord) -> String {
        renderBlock(annotation) + "\n"
    }

    /// Multi-card snapshot, used by the popover-level "Add all to chat"
    /// action. Cards are emitted in the order they appear in the input —
    /// callers pass records already sorted by `(createdAt ASC, id ASC)`.
    ///
    /// Format: each card rendered as in `compose(annotation:)`, separated
    /// by a blank line. Result has a trailing newline for the same reason
    /// the single-card form does.
    public static func compose(annotations: [BibleAnnotationRecord]) -> String {
        guard !annotations.isEmpty else { return "" }
        return annotations.map(renderBlock).joined(separator: "\n\n") + "\n"
    }

    /// One card's markdown, without trailing newline. Title is rendered as
    /// an H2 — short enough that the LLM can scan the snapshot without
    /// drowning in heading markup; structured enough that the cards stay
    /// visually distinct in the composer.
    private static func renderBlock(_ record: BibleAnnotationRecord) -> String {
        "## \(record.title)\n\n\(record.body)"
    }
}
