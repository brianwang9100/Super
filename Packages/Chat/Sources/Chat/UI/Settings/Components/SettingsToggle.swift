import SwiftUI

/// Custom 44×26 iOS-style toggle. Mirrors `Switch` from `settings.jsx`:
/// accent-filled track when on, `border` track when off, white thumb that
/// translates 18pt with a `.linear(0.2)` ease.
///
/// SwiftUI's native `Toggle` would give us the right behaviour but the
/// system style isn't accent-tinted in the same way and the disabled state
/// is too dim against `--bg-raised`. The custom switch keeps pixel parity.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    /// Spoken label for VoiceOver. Required so users hear the *thing* the
    /// toggle controls (e.g. "Opus 4.7") rather than just "On, button".
    let accessibilityLabel: String

    @Environment(\.superTheme) private var theme

    init(isOn: Binding<Bool>, accessibilityLabel: String) {
        self._isOn = isOn
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Button(action: { isOn.toggle() }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? theme.accent : theme.border)
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 1)
                    .frame(width: 22, height: 22)
                    .padding(.horizontal, 2)
            }
            .frame(width: 44, height: 26)
        }
        .buttonStyle(.plain)
        .animation(.linear(duration: 0.2), value: isOn)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
    }
}
