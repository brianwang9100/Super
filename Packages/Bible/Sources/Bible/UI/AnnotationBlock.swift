import Core
import SwiftUI

struct AnnotationBlock: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var verseBodySize: CGFloat = SuperTypography.readingBodySize

    let title: String
    let verseText: String?
    let summary: String
    let provenance: String
    var treatAsPartial = false
    var isWorking = false
    var onCopy: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !title.isEmpty {
                Text(title)
                    .font(typography.reading(22, relativeTo: .title2, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let verseText, !verseText.isEmpty {
                Text(verseText)
                    .font(typography.reading(verseBodySize, relativeTo: nil))
                    .lineSpacing(BibleReadingMetrics.lineSpacing(bodySize: verseBodySize, fontScale: typography.fontScale))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.borderFaint).frame(width: 3)
                    }
            }
            ResponseTextBlock(text: summary, treatAsPartial: treatAsPartial, isWorking: isWorking)
            if let onCopy, let onRegenerate {
                HStack(spacing: 8) {
                    ResponseActions(onCopy: onCopy, onRegenerate: onRegenerate)
                    if isCopied {
                        Text("Copied")
                            .font(typography.font(.caption))
                            .foregroundStyle(theme.inkSoft)
                            .accessibilityLabel("Annotation copied")
                    }
                }
            }
            if !provenance.isEmpty {
                Text(provenance)
                    .font(typography.font(size: 10, weight: .regular, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(theme.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
