import Core
import SwiftUI

struct SuggestedActions: View {
    let actions: [SuggestedChatAction]
    let onSend: (String) -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(actions) { action in
                Button {
                    onSend(action.message)
                } label: {
                    Text(action.label)
                        .font(typography.font(.subheadline))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .superGlassButton(in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
