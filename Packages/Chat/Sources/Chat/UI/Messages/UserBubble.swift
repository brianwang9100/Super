import SwiftUI

/// Right-aligned soft-green chat bubble for a single user-authored message.
/// Tail corner (bottom-right) uses a tighter radius so the bubble reads as
/// "from the user" without an avatar/role label. Verse-reference pills, if
/// any, render read-only above the text bubble; a pills-only message (empty
/// `text`) renders just the pills.
struct UserBubble: View {
    let text: String
    /// Read-only verse-reference pills attached to this message. Empty for
    /// an ordinary text message.
    var references: [VerseReferencePillModel] = []
    @Environment(\.superTheme) private var theme
    @Environment(\.chatAppearance) private var appearance
    /// Base body size, declared via `@ScaledMetric` so the rendered
    /// point size composes Dynamic Type with the chat font-scale knob —
    /// at XXL the user bubble grows beyond plain markdown body, matching
    /// the pre-`ChatAppearance` behavior.
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
            .font(.system(size: basePoint * appearance.fontScale))
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
