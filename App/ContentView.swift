import Chat
import Core
import SwiftUI

/// App-level shell content. Renders the live `ChatScreen` once the
/// bootstrap dependency graph is `.ready`, a transient progress pane
/// during `.loading`, and an inline error pane when the bootstrap fails.
///
/// The Sidebar (M8) and Settings (M9) entry points are wired here later;
/// for M7 the hamburger button on the header is a no-op.
struct ContentView: View {
    let state: BootstrapState

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPane()
            case .failed(let message):
                FailurePane(message: message)
            case .ready(let dependencies):
                ChatHostView(dependencies: dependencies)
            }
        }
    }
}

// MARK: - Loading / failure

private struct LoadingPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Super")
                .font(.system(size: 36, weight: .regular, design: .serif))
                .italic()
            ProgressView("Starting Super…")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailurePane: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bootstrap failed")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Chat host (M7)

/// Hosts the live `ChatScreen` once the bootstrap is ready. Builds the
/// view model from the dependency graph, applies the default theme, and
/// seeds a starter conversation row on first launch so the user lands on
/// a valid chat instead of an empty store.
struct ChatHostView: View {
    let dependencies: AppDependencies

    @State private var viewModel: ChatScreenViewModel?
    @State private var bootstrapError: String?
    @State private var theme: SuperTheme = .make(.light)
    /// Set the moment `ensureViewModel` enters its critical section so a
    /// re-fired `.task` (scene refresh, identity change) can't race a
    /// second bootstrap before the first finishes. Safe to read/write
    /// without coordination because `.task` runs on the main actor.
    @State private var bootstrapStarted = false

    var body: some View {
        Group {
            if let viewModel {
                ChatScreen(
                    viewModel: viewModel,
                    onMenuTap: {
                        // Sidebar drawer ships in M8.
                    }
                )
                .superTheme(theme)
            } else if let bootstrapError {
                FailurePane(message: bootstrapError)
            } else {
                LoadingPane()
            }
        }
        .task {
            await ensureViewModel()
        }
    }

    private func ensureViewModel() async {
        guard !bootstrapStarted else { return }
        bootstrapStarted = true
        do {
            let conversation = try await ensureConversation()
            let session = await dependencies.chatSessionStore.session(for: conversation.id)
            let driver = LiveChatSessionDriver(session: session)
            let providers = await dependencies.llmProviderRegistry.allProviders()
            let providerModels = providers.flatMap(\.supportedModels)
            viewModel = ChatScreenViewModel(
                conversationId: conversation.id,
                conversationTitle: conversation.title ?? "New chat",
                driver: driver,
                messageRepository: dependencies.messageRepository,
                toolCallRepository: dependencies.toolCallRepository,
                checkpointRepository: dependencies.checkpointRepository,
                availableModels: providerModels,
                selectedModelId: providerModels.first?.id
            )
        } catch {
            bootstrapError = "Could not open chat: \(error.localizedDescription)"
        }
    }

    /// Returns the most-recently-updated conversation, creating a starter
    /// row when the database is empty.
    // M8: replace with selection-driven loader when the sidebar lands.
    private func ensureConversation() async throws -> ConversationRecord {
        let existing = try await dependencies.conversationRepository.listActive()
        if let row = existing.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            return row
        }
        let now = Date()
        let row = ConversationRecord(
            id: UUID().uuidString,
            title: "New chat",
            createdAt: now,
            updatedAt: now
        )
        try await dependencies.conversationRepository.save(row)
        return row
    }
}

// MARK: - Previews

#Preview("loading") {
    ContentView(state: .loading)
}

#Preview("failed") {
    ContentView(state: .failed("could not open chat.sqlite"))
}
