import SwiftUI

/// UI-local projection of a `RecordReference` for the composer strip and
/// the sent user bubble. Keeps `MessageList` and `ChatComposer` free of
/// Core imports — they render pills from this, never the Core type.
public struct VerseReferencePillModel: Identifiable, Sendable, Equatable {
    /// Matches the originating `RecordReference.id` so removal and dedupe
    /// can key off it.
    public let id: String
    /// Chip text, e.g. `"John 3:16-17 (WEB)"`.
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Small inline rounded chip showing an attached reference — a Bible verse
/// range today — with an optional remove (×) control. Rendered in a strip
/// above the composer's text field and, read-only, inside a sent
/// `UserBubble`.
struct VerseReferencePill: View {
    let label: String
    /// `nil` renders the pill read-only (no × button) — used in the sent
    /// message bubble, where the attachment is immutable.
    let onRemove: (() -> Void)?

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Base chip text size, declared via `@ScaledMetric` so the pill
    /// composes OS Dynamic Type on top of the app font-scale that
    /// `SuperTypography` folds in. The typography system path ignores
    /// `relativeTo`, so this metric is how the view opts into Dynamic Type.
    @ScaledMetric(relativeTo: .caption) private var basePoint: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "book.closed.fill")
                .font(typography.font(size: basePoint * 0.85))
            Text(label)
                .font(typography.font(size: basePoint, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(typography.font(size: basePoint * 0.8, weight: .bold))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label)")
            }
        }
        .foregroundStyle(theme.accent)
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 5)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.accentSoft))
        // Combine the glyph + label into one VoiceOver element; the ×
        // button stays its own focusable element with its own label.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bible reference, \(label)")
    }
}
