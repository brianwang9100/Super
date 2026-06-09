import SwiftUI

/// Data pane: a chat-export group on top, then a destructive "Clear chat
/// history" group whose trailing label paints in warm red.
///
/// The export group is a small state machine driven by
/// ``ChatExportController/phase`` — Export → (spinner + Cancel) → Download
/// (share sheet). Import was removed (not needed for v1).
struct SettingsDataPane: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showsConfirmation = false

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private var exportController: ChatExportController { viewModel.exportController }

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup {
                exportContent
            }

            SettingsGroup {
                SettingsRow(
                    label: "Clear chat history",
                    borderBottom: false,
                    accessibilityHint: "Deletes every conversation. Cannot be undone.",
                    trailing: {
                        Text("Delete")
                            .font(typography.font(.subheadline))
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

    @ViewBuilder
    private var exportContent: some View {
        switch exportController.phase {
        case .idle:
            SettingsRow(
                label: "Export all chats",
                value: ".json",
                borderBottom: false,
                action: { exportController.start() }
            )

        case .exporting:
            SettingsRow(
                label: "Exporting…",
                borderBottom: false,
                accessibilityHint: "Tap to cancel the export.",
                trailing: {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Cancel")
                            .font(typography.font(.subheadline))
                            .foregroundStyle(theme.errorAccent)
                    }
                },
                action: { exportController.cancel() }
            )

        case let .finished(url, conversationCount):
            downloadRow(url: url, conversationCount: conversationCount)
            SettingsRow(
                label: "Export again",
                isInteractive: true,
                borderBottom: false,
                action: {
                    exportController.reset()
                    exportController.start()
                }
            )

        case let .failed(message):
            SettingsRow(
                label: "Export failed — tap to retry",
                borderBottom: false,
                accessibilityHint: message,
                trailing: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(typography.font(.subheadline))
                        .foregroundStyle(theme.errorAccent)
                },
                action: { exportController.start() }
            )
        }
    }

    /// The finished-state download affordance. It is a `ShareLink` styled to
    /// match `SettingsRow` rather than a `SettingsRow` (whose `Button` would
    /// swallow the share tap — same reason Bible's action sheet makes the
    /// `ShareLink` the button itself).
    private func downloadRow(url: URL, conversationCount: Int) -> some View {
        ShareLink(item: url) {
            HStack(spacing: 14) {
                Text("Download export")
                    .font(typography.font(.callout))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(countLabel(conversationCount))
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.inkFaint)
                Image(systemName: "square.and.arrow.up")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.inkSoft)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 1)
                    .padding(.leading, 18)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download export, \(countLabel(conversationCount))")
    }

    private func countLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "chat" : "chats") · .json"
    }
}
