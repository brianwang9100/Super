import Core
import SwiftUI

/// Data pane: a chat-export group on top, then a destructive "Clear chat
/// history" group whose trailing label paints in warm red.
///
/// Export is a single always-present share control rather than a multi-step
/// state machine: tapping the glass share disc spins up a *fresh* `.json`
/// archive (``ChatExportController/start()`` discards any prior file) and, on
/// completion, auto-presents the system share sheet. There is no separate
/// "finished" row to tap — the share screen is the destination. Import was
/// removed (not needed for v1).
struct SettingsDataPane: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showsConfirmation = false
    /// Non-nil once a fresh archive is ready, which drives the share sheet.
    /// Cleared by `.sheet(item:)` on dismiss, so the next export (a fresh
    /// `.finished` phase) re-presents it.
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
        // No eager temp-file cleanup on dismiss: `UIActivityViewController`
        // activities (Save to Files, AirDrop, Mail) can read the file URL
        // *after* the sheet dismisses, so deleting it here would race them.
        // The next export's `ChatExportController.start()` removes the prior
        // file (`cleanUpLastFile()`), and the OS reaps the temp dir otherwise.
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

    /// The export affordance: a leading label/status column trailed by a single
    /// circular Liquid Glass share button. Tapping it builds a fresh archive
    /// (the disc shows a spinner meanwhile) and presents the share sheet. A
    /// failed run swaps the status line to an error and leaves the disc tappable
    /// to retry.
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
            .buttonStyle(.plain)
            .disabled(isExporting)
            .accessibilityLabel("Export and share all chats")
            .accessibilityHint(isFailed ? statusMessage : "Builds a fresh .json and opens the share sheet.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    /// A 44pt circular glass disc (the standard nav-button hit target): a
    /// spinner while exporting, otherwise the share glyph.
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

    /// The system share sheet for the freshly written archive. UIKit-only; the
    /// macOS test build falls back to an empty view (the sheet never presents
    /// there).
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
}

/// Identifies the in-flight share by its file URL so `.sheet(item:)`
/// re-presents on each fresh export (every run writes a unique path).
private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}
