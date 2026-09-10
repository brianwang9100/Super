import Foundation

/// Chat receives the stored Markdown verbatim; UI-only citation links are not embedded.
public enum AnnotationSnapshotComposer {
    /// A trailing newline separates the snapshot from surrounding composer text.
    public static func compose(annotation: BibleAnnotationRecord, citation: String) -> String {
        "## \(citation) — annotation\n\n\(annotation.summary)\n"
    }
}
