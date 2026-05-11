import SwiftUI

/// Small 26pt icon-only button used by ``AssistantMessage`` for the
/// Copy / Regenerate row beneath each assistant reply.
struct MessageActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @Environment(\.superTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(.caption))
                .foregroundStyle(theme.inkFaint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
