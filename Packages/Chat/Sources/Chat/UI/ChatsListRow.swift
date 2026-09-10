import Core
import Foundation
import SwiftUI

struct ChatsListRow: View {
    let title: String

    let updatedAt: Date

    let now: Date

    let onTap: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// System faces need ScaledMetric to combine Dynamic Type with app font scaling.
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    // Weight and color preserve hierarchy when Dynamic Type sizes converge.
    @ScaledMetric(relativeTo: .footnote) private var subtitleSize: CGFloat = 13

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(typography.font(size: titleSize, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(RelativeTimeFormatter.format(updatedAt, now: now))
                        .font(typography.font(size: subtitleSize))
                        .foregroundStyle(theme.inkFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(typography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.inkMute)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}
