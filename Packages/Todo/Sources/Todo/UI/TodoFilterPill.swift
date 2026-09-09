import Core
import SwiftUI

public struct TodoFilterPill: View {
    public let summary: String
    public let onTap: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var chevronSize: CGFloat = 10
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    public init(summary: String, onTap: @escaping () -> Void) {
        self.summary = summary
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(typography.font(size: iconSize, weight: .semibold))
                Text(summary)
                    .font(typography.font(size: textSize, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(typography.font(size: chevronSize, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(theme.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .superGlassButton(in: Capsule())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("Filter and sort")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the filter options")
    }
}
