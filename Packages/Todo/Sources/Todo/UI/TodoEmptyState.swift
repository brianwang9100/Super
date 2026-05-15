import Core
import SwiftUI

/// Centered placeholder shown when the filtered task list is empty.
/// Mirrors the empty branch of the list in the Todo design source's
/// `app.jsx`.
public struct TodoEmptyState: View {
    @ScaledMetric(relativeTo: .title2) private var headlineSize: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var captionSize: CGFloat = 13
    @Environment(\.superTheme) private var theme

    public init() {}

    public var body: some View {
        VStack(spacing: 6) {
            Text("Nothing here.")
                .font(.system(size: headlineSize, design: .serif))
                .foregroundStyle(theme.inkSoft)
            Text("Adjust your filter or tap ＋ to add a task.")
                .font(.system(size: captionSize))
                .foregroundStyle(theme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }
}
