import SwiftUI

/// Right-aligned soft-green chat bubble for a single user-authored message.
/// Tail corner (bottom-right) uses a tighter radius so the bubble reads as
/// "from the user" without an avatar/role label.
struct UserBubble: View {
    let text: String
    @Environment(\.superTheme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(.subheadline))
                .lineSpacing(2)
                .foregroundStyle(theme.bubbleInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
        .padding(.vertical, 4)
    }
}
