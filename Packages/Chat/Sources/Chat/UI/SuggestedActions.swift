import Core
import SwiftUI

/// Bottom-right cluster of empty-state chat-starter buttons. Each renders a
/// `SuggestedChatAction` as a tappable glass capsule that sends the action's
/// `message` when tapped. The actions are contributed by the registered applets
/// and aggregated by the shell; this Region only lays them out and forwards
/// taps to `onSend`.
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
