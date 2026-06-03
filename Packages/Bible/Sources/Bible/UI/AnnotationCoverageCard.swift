import Core
import SwiftUI

/// Honest three-level synopsis at the top of the Annotations hub: how much of
/// the Bible carries annotations, counted in **books · chapters · verses**. No
/// invented "fullness", no note counts — each column is `annotated / total`.
struct AnnotationCoverageCard: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let coverage: AnnotationCoverage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ANNOTATED")
                .font(typography.mono(10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

            HStack(spacing: 0) {
                stat(value: coverage.books, total: coverage.totalBooks, label: "BOOKS", leadingDivider: false)
                stat(value: coverage.chapters, total: coverage.totalChapters, label: "CHAPTERS", leadingDivider: true)
                stat(value: coverage.verses, total: coverage.totalVerses, label: "VERSES", leadingDivider: true)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.borderFaint, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Annotated: \(coverage.books) of \(coverage.totalBooks) books, "
            + "\(coverage.chapters) of \(coverage.totalChapters) chapters, "
            + "\(coverage.verses) of \(coverage.totalVerses) verses"
        )
    }

    @ViewBuilder
    private func stat(value: Int, total: Int, label: String, leadingDivider: Bool) -> some View {
        HStack(spacing: 0) {
            if leadingDivider {
                Rectangle().fill(theme.borderFaint).frame(width: 1).frame(maxHeight: 34)
            }
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value.formatted())
                        .font(typography.mono(21, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.ink)
                    Text("/\(total.formatted())")
                        .font(typography.mono(11))
                        .foregroundStyle(theme.inkMute)
                }
                // Keep "value /total" on one line — at high coverage the verses
                // column ("1,204 /31,102") would otherwise wrap; shrink to fit
                // the third-of-width column instead.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Text(label)
                    .font(typography.mono(9.5))
                    .tracking(0.5)
                    .foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
        }
    }
}

/// Plain coverage snapshot the card renders — distinct annotated counts over
/// the canonical totals (66 books · 1,189 chapters · 31,102 verses).
public struct AnnotationCoverage: Sendable, Equatable {
    public var books: Int
    public var chapters: Int
    public var verses: Int
    public var totalBooks: Int
    public var totalChapters: Int
    public var totalVerses: Int

    public init(
        books: Int,
        chapters: Int,
        verses: Int,
        totalBooks: Int = 66,
        totalChapters: Int = 1_189,
        totalVerses: Int = 31_102
    ) {
        self.books = books
        self.chapters = chapters
        self.verses = verses
        self.totalBooks = totalBooks
        self.totalChapters = totalChapters
        self.totalVerses = totalVerses
    }

    /// Empty coverage — the `@Query` default and the fresh-install state.
    public static let none = AnnotationCoverage(books: 0, chapters: 0, verses: 0)
}
