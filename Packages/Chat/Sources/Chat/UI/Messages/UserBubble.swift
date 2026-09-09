import SwiftUI

struct UserBubble: View {
    let text: String
    var references: [VerseReferencePillModel] = []
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.chatAppearance) private var appearance
    /// System faces need ScaledMetric to combine Dynamic Type with app font scaling.
    @ScaledMetric(relativeTo: .subheadline) private var basePoint: CGFloat = 17

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(references) { reference in
                    VerseReferencePill(label: reference.label, onRemove: nil)
                }
                if !text.isEmpty {
                    textBubble
                }
            }
        }
        .padding(.vertical, appearance.bubbleRowVerticalPadding)
    }

    private var textBubble: some View {
        Text(text)
            .font(typography.font(size: basePoint))
            .lineSpacing(2)
            .foregroundStyle(theme.bubbleInk)
            .padding(.horizontal, 14)
            .padding(.vertical, appearance.bubbleInnerVerticalPadding)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: 18,
                        bottomLeading: 18,
                        bottomTrailing: 6,
                        topTrailing: 18
                    ),
                    style: .continuous
                ).fill(theme.bubbleUser)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
