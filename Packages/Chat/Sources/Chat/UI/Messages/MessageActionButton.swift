import SwiftUI

/// Small 26pt icon-only button used by ``AssistantMessage`` for the
/// Copy / Regenerate row beneath each assistant reply.
struct MessageActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    /// When `true`, the button still renders so the action row's layout
    /// stays stable, but taps are ignored and the glyph dims to half
    /// opacity. Regenerate uses this during in-flight streaming.
    var disabled: Bool = false
    @Environment(\.superTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(.caption))
                .foregroundStyle(theme.inkFaint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }
}
