import Core
import SwiftUI

/// One note rendered as a row in `NoteListSheet`.
///
/// Anatomy mirrors the Claude Design canvas (`notes/sheet.jsx`):
///
/// - **Date written** — a small uppercase monospaced line (the note's
///   `createdAt`, pre-formatted by the caller).
/// - **Body** — the note text, clamped to `lineLimit` lines with a tail
///   ellipsis so a long note doesn't blow out the row height.
/// - **Provenance footer** — assistant-written notes only: a `sparkles`
///   glyph + "Written by {author}". User notes have no footer.
///
/// Stateless: the row owns no selection or delete state. The list sheet
/// supplies the tap (→ edit) and swipe-to-delete affordances around it.
/// The note's content parameter is named `text` rather than `body` to
/// avoid shadowing SwiftUI's `View.body` requirement on this type — the
/// same rename rationale `AnnotationBlock.Content` follows.
struct NoteCard: View {
    @Environment(\.superTheme) private var theme

    /// Pre-formatted "date written", e.g. `"May 24, 2026"`. Uppercased
    /// for display here. The caller formats it because date formatting
    /// belongs with the coordinator that already holds a formatter, not
    /// in a leaf view rendered once per row.
    let dateWritten: String
    let text: String
    /// Non-nil ⇒ an assistant-written note; renders the provenance footer
    /// naming the author. `nil` for user-typed notes (no footer).
    let author: String?
    let lineLimit: Int

    // Font sizes carried as scaled metrics so the card tracks Dynamic Type —
    // the design's fixed point sizes, scaled relative to the nearest system
    // text style (the `BibleBookSheet` convention).
    @ScaledMetric(relativeTo: .caption2) private var dateSize: CGFloat = 10.5
    @ScaledMetric(relativeTo: .subheadline) private var bodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var provenanceSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var sparkleSize: CGFloat = 11

    init(dateWritten: String, text: String, author: String? = nil, lineLimit: Int = 4) {
        self.dateWritten = dateWritten
        self.text = text
        self.author = author
        self.lineLimit = lineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateWritten.uppercased())
                .font(.system(size: dateSize, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(theme.inkFaint)
                .lineLimit(1)
            Text(text)
                .font(.system(size: bodySize))
                .lineSpacing(3)
                .foregroundStyle(theme.ink)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let author {
                provenance(author: author)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.backgroundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.borderFaint, lineWidth: 0.5)
        )
    }

    private func provenance(author: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: sparkleSize, weight: .medium))
                .foregroundStyle(theme.inkMute)
            Text("Written by \(author)")
                .font(.system(size: provenanceSize, weight: .regular, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(theme.inkMute)
                .lineLimit(1)
        }
        .padding(.top, 4)
    }
}
