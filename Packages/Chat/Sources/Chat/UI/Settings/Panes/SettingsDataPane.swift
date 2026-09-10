import Core
import SwiftUI

struct SettingsDataPane: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showsConfirmation = false
    @State private var shareItem: ShareItem?

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
        .onChange(of: exportController.phase) { _, phase in
            if case let .finished(url, _) = phase {
                shareItem = ShareItem(url: url)
            }
        }
        // Share activities may read the URL after dismissal. Leave cleanup to the next export or the OS.
        .sheet(item: $shareItem) { item in
            shareSheet(for: item.url)
        }
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

    private var exportContent: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export all chats")
                    .font(typography.font(.callout))
                    .foregroundStyle(theme.ink)
                Text(statusMessage)
                    .font(typography.font(.subheadline))
                    .foregroundStyle(isFailed ? theme.errorAccent : theme.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                exportController.start()
            } label: {
                shareDisc
            }
            .buttonStyle(GlassHapticButtonStyle(.selection))
            .disabled(isExporting)
            .accessibilityLabel(isExporting ? "Exporting chats" : "Export and share all chats")
            .accessibilityHint(exportAccessibilityHint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var shareDisc: some View {
        Group {
            if isExporting {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(typography.font(.body))
                    .foregroundStyle(theme.ink)
            }
        }
        .frame(width: 44, height: 44)
        .superGlassButton(in: Circle())
    }

    @ViewBuilder
    private func shareSheet(for url: URL) -> some View {
        #if canImport(UIKit)
        ShareSheet(items: [url])
        #else
        EmptyView()
        #endif
    }

    private var isExporting: Bool { exportController.phase == .exporting }

    private var isFailed: Bool {
        if case .failed = exportController.phase { return true }
        return false
    }

    private var statusMessage: String {
        if case let .failed(message) = exportController.phase { return message }
        return ".json"
    }

    private var exportAccessibilityHint: String {
        if isExporting { return "Export is in progress." }
        if isFailed { return statusMessage }
        return "Builds a fresh .json and opens the share sheet."
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}
