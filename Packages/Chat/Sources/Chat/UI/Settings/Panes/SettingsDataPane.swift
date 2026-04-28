import SwiftUI

/// Data pane. Mirrors `DataPane` from `settings.jsx`: an Export/Import
/// group on top, then a destructive "Clear chat history" group whose
/// trailing label paints in warm red.
struct SettingsDataPane: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showsConfirmation = false

    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup {
                SettingsRow(
                    label: "Export all chats",
                    value: ".json",
                    action: { /* MVP no-op; ships with sync engine. */ }
                )
                SettingsRow(
                    label: "Import chats",
                    borderBottom: false,
                    action: { /* MVP no-op. */ }
                )
            }

            SettingsGroup {
                SettingsRow(
                    label: "Clear chat history",
                    borderBottom: false,
                    accessibilityHint: "Deletes every conversation. Cannot be undone.",
                    trailing: {
                        Text("Delete")
                            .font(.system(.subheadline))
                            .foregroundStyle(theme.errorAccent)
                    },
                    action: { showsConfirmation = true }
                )
            }
        }
        .padding(.top, 16)
        .confirmationDialog(
            "Delete every chat?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.clearChatHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conversations and messages are removed locally. This can't be undone.")
        }
    }
}
