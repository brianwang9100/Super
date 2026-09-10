import SwiftUI

/// Custom chrome retains the design's accent and disabled-state contrast.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String

    @Environment(\.superTheme) private var theme
    /// Explicit accessibility actions can bypass disabled; gate them with the button action.
    @Environment(\.isEnabled) private var isEnabled

    init(isOn: Binding<Bool>, accessibilityLabel: String) {
        self._isOn = isOn
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Button(action: handleTap) {
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
        .accessibilityAction { handleTap() }
    }

    private func handleTap() {
        Self.commit(isOn: $isOn, isEnabled: isEnabled)
    }

    static func commit(isOn: Binding<Bool>, isEnabled: Bool) {
        guard isEnabled else { return }
        isOn.wrappedValue.toggle()
    }
}
