import Core
import SwiftUI

struct NoteCard: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let dateWritten: String
    let text: String
    /// Nil hides provenance for user-authored notes.
    let author: String?
    let lineLimit: Int

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
                .font(typography.font(size: dateSize, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(theme.inkFaint)
                .lineLimit(1)
            Text(text)
                .font(typography.font(size: bodySize))
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
                .font(typography.font(size: sparkleSize, weight: .medium))
                .foregroundStyle(theme.inkMute)
            Text("Written by \(author)")
                .font(typography.font(size: provenanceSize, weight: .regular, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(theme.inkMute)
                .lineLimit(1)
        }
        .padding(.top, 4)
    }
}
