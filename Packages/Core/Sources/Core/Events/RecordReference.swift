import Foundation

/// A cross-applet pointer to a record one applet hands to another, carrying
/// everything the receiver needs to render and expand it without importing
/// the source applet or its database.
///
/// Deliberately generic — the receiver treats every field as opaque
/// display/expansion data. Today the only producer is the Bible applet
/// handing a verse range to the Chat composer.
///
/// The same value travels the event bus *and* is persisted (encoded into a
/// message's attachment column), so it conforms to `Codable` as well as
/// `Sendable`.
public struct RecordReference: Sendable, Equatable, Codable, Identifiable {
    /// Source applet's identifier (e.g. `"bible"`).
    public let appletID: String
    /// Source-defined record kind discriminator (e.g. `"verseRange"`).
    public let kind: String
    /// Source-canonical identifier — opaque to the receiver. For a Bible
    /// verse range: `"WEB/JHN/3/16-17"`. Lets a future round-trip
    /// re-resolve the record in its origin applet.
    public let sourceID: String
    /// Stable identity for this reference instance, distinct from
    /// `sourceID` so two adds of the same verse are separate pills.
    public let id: String
    /// Short human label for the pill chip, e.g. `"John 3:16-17 (WEB)"`.
    public let displayLabel: String
    /// Canonical citation line used when expanding the reference for the
    /// LLM, e.g. `"John 3:16-17 (WEB)"`.
    public let citation: String
    /// Verbatim content snapshot captured at add-time. The receiver
    /// expands `citation` + this into the message it sends, so the model
    /// never has to recall the text itself — load-bearing for BYOK small
    /// or local models that misquote scripture.
    public let snapshot: String

    public init(
        appletID: String,
        kind: String,
        sourceID: String,
        displayLabel: String,
        citation: String,
        snapshot: String,
        id: String = UUID().uuidString
    ) {
        self.appletID = appletID
        self.kind = kind
        self.sourceID = sourceID
        self.id = id
        self.displayLabel = displayLabel
        self.citation = citation
        self.snapshot = snapshot
    }
}
