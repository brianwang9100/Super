import SwiftUI

public struct ChatHeader: View {
    public let title: String

    public init(title: String) {
        self.title = title
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// System faces ignore relativeTo, so ScaledMetric adds Dynamic Type to app font scaling.
    @ScaledMetric(relativeTo: .subheadline) private var titleBase: CGFloat = 17

    public var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: 0)
            Text(title)
                .font(typography.font(size: titleBase, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
