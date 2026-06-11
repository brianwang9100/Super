import Core
import SwiftUI

/// Tappable pill showing the active filter summary. Tapping opens the
/// filter sheet. Mirrors `FilterPill` in the Todo design source's
/// `components.jsx`.
public struct TodoFilterPill: View {
    public let summary: String
    public let onTap: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var chevronSize: CGFloat = 10
    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme

    public init(summary: String, onTap: @escaping () -> Void) {
        self.summary = summary
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: iconSize * fontScale, weight: .semibold))
                Text(summary)
                    .font(.system(size: textSize * fontScale, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSize * fontScale, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(theme.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // Whole pill is the tap target, so the hit-region-asserting glass
            // button is right; it supplies its own frosted edge in place of
            // the old raised fill + faint stroke.
            .superGlassButton(in: Capsule())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("Filter and sort")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the filter options")
    }
}
