import Core
import SwiftUI

/// Tappable pill showing the active filter summary. Tapping opens the
/// filter sheet. Mirrors `FilterPill` in the Todo design source's
/// `components.jsx`.
public struct TodoFilterPill: View {
    public let summary: String
    public let onTap: () -> Void

    @Environment(\.superTheme) private var theme

    public init(summary: String, onTap: @escaping () -> Void) {
        self.summary = summary
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(theme.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.backgroundRaised)
            .overlay(Capsule().strokeBorder(theme.borderFaint, lineWidth: 0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
