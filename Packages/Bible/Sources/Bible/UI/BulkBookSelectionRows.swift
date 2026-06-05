import Core
import SwiftUI

/// A selectable book in the Generate sheet. The checkbox toggles selection of
/// the whole book; tapping the rest of the row expands it to reveal chapters.
/// A fully-annotated book shows a "Done" badge; a mixed one shows "partial".
struct BulkBookSelectionRow: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let name: String
    let chapterCount: Int
    let checked: Bool
    let partial: Bool
    let done: Bool
    let expanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSelect) {
                BulkCheckBox(checked: checked, partial: partial)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Deselect \(name)" : "Select \(name)")

            Button(action: onToggleExpand) {
                HStack(spacing: 12) {
                    Text(name)
                        .font(typography.font(.subheadline, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if done {
                        AnnotationDoneBadge()
                    } else if partial {
                        Text("partial")
                            .font(typography.mono(10.5, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                    Text("\(chapterCount) ch")
                        .font(typography.mono(11))
                        .foregroundStyle(theme.inkMute)
                        .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.inkMute)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(chapterCount) chapters\(done ? ", done" : "")")
            .accessibilityHint(expanded ? "Collapse chapters" : "Expand chapters")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.borderFaint).frame(height: 0.5)
        }
    }
}

/// An indented chapter line revealed under an expanded book. Shares the book
/// cells' background; a fully-annotated chapter shows a "Done" badge.
struct BulkChapterSelectionRow: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let number: Int
    let checked: Bool
    let done: Bool
    let onToggleSelect: () -> Void

    var body: some View {
        Button(action: onToggleSelect) {
            HStack(spacing: 12) {
                BulkCheckBox(checked: checked)
                Text("Chapter \(number)")
                    .font(typography.font(.footnote))
                    .foregroundStyle(theme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if done {
                    AnnotationDoneBadge()
                }
            }
            .padding(.leading, 42)
            .padding(.trailing, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(theme.background)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.borderFaint).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chapter \(number)\(done ? ", done" : "")")
    }
}
