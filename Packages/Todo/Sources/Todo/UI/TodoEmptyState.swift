import Core
import SwiftUI

public struct TodoEmptyState: View {
    @ScaledMetric(relativeTo: .title2) private var headlineSize: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var captionSize: CGFloat = 15
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    public init() {}

    public var body: some View {
        VStack(spacing: 6) {
            Text("Nothing here.")
                .font(typography.display(headlineSize, relativeTo: nil))
                .foregroundStyle(theme.inkSoft)
            Text("Adjust your filter or tap ＋ to add a task.")
                .font(typography.font(size: captionSize))
                .foregroundStyle(theme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }
}
