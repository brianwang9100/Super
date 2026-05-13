import Chat
import Core
import SwiftUI

/// App-level shell content. Renders the live `ChatScreen` once the
/// bootstrap dependency graph is `.ready`, a transient progress pane
/// during `.loading`, and an inline error pane when the bootstrap fails.
///
/// The Sidebar (M8) and Settings (M9) overlays are hosted by
/// `ChatHostView` so the chat surface stays a pure presentation of the
/// active conversation.
struct ContentView: View {
    let state: BootstrapState

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingScreen()
            case .failed(let message):
                FailureScreen(message: message)
            case .ready(let dependencies):
                ChatHostView(dependencies: dependencies)
            }
        }
    }
}

// MARK: - Loading / failure

private struct LoadingScreen: View {
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

private struct FailureScreen: View {
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

// MARK: - Chat host (M7 + M8)

/// Hosts the live `ChatScreen` once the bootstrap is ready. Builds the
/// view model from the dependency graph, applies the default theme, and
/// drops the user into a fresh draft chat on every launch — previously
/// persisted conversations stay in the sidebar drawer for one-tap recall.
/// The draft only hits disk if the user actually sends a message (lazy
/// persist), so launching and quitting doesn't litter the store with
/// empty rows.
///
/// In M8 this also owns the sidebar drawer state. The drawer overlays the
/// chat in a `ZStack`; selecting a different conversation rebuilds the
/// chat view model so the transcript reloads.
struct ChatHostView: View {
    let dependencies: AppDependencies

    @State private var viewModel: ChatScreenViewModel?
    @State private var sidebarViewModel: SidebarViewModel?
    @State private var settingsViewModel: SettingsViewModel?
    @State private var bootstrapError: String?
    @State private var theme: SuperTheme = .make(.light)
    @State private var sidebarOpen: Bool = false
    @State private var settingsOpen: Bool = false
    @State private var activeConversationId: String?
    /// Set the moment `ensureViewModel` enters its critical section so a
    /// re-fired `.task` (scene refresh, identity change) can't race a
    /// second bootstrap before the first finishes. Safe to read/write
    /// without coordination because `.task` runs on the main actor.
    @State private var bootstrapStarted = false

    private var appInfo: SuperAppInfo { .fromBundle() }

    var body: some View {
        ZStack {
            if let viewModel {
                ChatScreen(
                    viewModel: viewModel,
                    onMenuTap: openSidebar,
                    onManageModels: { openSettings(initialPane: .models) }
                )
                .superTheme(theme)
            } else if let bootstrapError {
                FailureScreen(message: bootstrapError)
            } else {
                LoadingScreen()
            }

            if let sidebarViewModel {
                SidebarDrawer(
                    isPresented: $sidebarOpen,
                    viewModel: sidebarViewModel,
                    appInfo: appInfo,
                    userInitials: "BW",
                    userName: "Brian Wang",
                    onSelectConversation: { id in
                        Task { await selectConversation(id: id) }
                    },
                    onNewChat: {
                        Task { await startNewChat() }
                    },
                    onOpenSettings: {
                        openSettings()
                    },
                    onSelectApplet: { _ in
                        // Other applets are visual placeholders in MVP.
                    }
                )
                .superTheme(theme)
            }

            if let settingsViewModel {
                SettingsSheet(
                    isPresented: $settingsOpen,
                    viewModel: settingsViewModel
                )
                .superTheme(theme)
            }
        }
        .task {
            await ensureViewModel()
        }
        .onChange(of: settingsViewModel?.settings.themeId) { _, newId in
            // Mirror persisted theme choice into the host's render theme so
            // the chat surface, sidebar, and sheet itself all repaint.
            if let newId {
                theme = .make(newId)
            }
        }
        .onChange(of: settingsViewModel?.models) { _, _ in
            // Refresh the composer's model picker whenever Settings adds,
            // edits, or deletes a model — `SettingsViewModel` already
            // re-registered/unregistered the matching `LLMProvider` with
            // the registry, so the picker just needs to re-pull.
            Task { await refreshAvailableModels() }
        }
    }

    private func openSidebar() {
        guard let sidebarViewModel else { return }
        sidebarOpen = true
        Task { await sidebarViewModel.refresh() }
    }

    private func openSettings(initialPane: SettingsSheet.Pane = .root) {
        guard let settingsViewModel else { return }
        // Seed the nav stack before flipping the visibility binding so the
        // sheet animates in already on the requested pane (e.g. the
        // composer's "Manage models…" jumping straight to Models).
        if initialPane != .root {
            settingsViewModel.openPane(initialPane)
        }
        settingsOpen = true
    }

    private func ensureViewModel() async {
        guard !bootstrapStarted else { return }
        bootstrapStarted = true
        do {
            let conversation = ensureConversation()
            // Whether this conversation came from disk or is a fresh
            // launch-into-empty-DB draft. Captured before
            // `rebuildChatViewModel` runs (which checks the DB itself
            // to decide whether to wrap the driver lazily).
            let isDraft = ((try? await dependencies.conversationRepository.fetch(id: conversation.id)) == nil)
            // Build the sidebar view model **before** the chat view
            // model so the chat's lazy-persist callback and the
            // auto-titler's `onTitleGenerated` hook can capture a
            // non-nil sidebar reference.
            let sidebar = SidebarViewModel(
                conversationRepository: dependencies.conversationRepository,
                sessionStore: dependencies.chatSessionStore,
                activeConversationId: conversation.id
            )
            sidebarViewModel = sidebar
            if isDraft {
                sidebar.draftConversation = conversation
            }
            await rebuildChatViewModel(for: conversation)
            await sidebar.refresh()

            let settings = SettingsViewModel(
                accountEmail: "brianwang9100@gmail.com",
                appInfo: appInfo,
                settingRepository: dependencies.settingRepository,
                modelRepository: dependencies.modelConfigurationRepository,
                conversationRepository: dependencies.conversationRepository,
                toolRegistry: dependencies.toolRegistry,
                systemPromptReceiver: dependencies.chatSessionStore,
                llmProviderRegistry: dependencies.llmProviderRegistry,
                httpClient: URLSessionHTTPClient()
            )
            await settings.load()
            settingsViewModel = settings
            theme = .make(settings.settings.themeId)
        } catch {
            bootstrapError = "Could not open chat: \(error.localizedDescription)"
        }
    }

    private func rebuildChatViewModel(for conversation: ConversationRecord) async {
        // Cancel any in-flight streaming task on the outgoing view model
        // so the dropped reference doesn't keep firing into a no-op
        // closure. The underlying `ChatSession` actor is also cancelled —
        // matches the visible UI state when the user switches chats.
        // TODO(M11): resume streaming UI when re-opening a conversation
        // that is mid-turn instead of silently terminating it here.
        viewModel?.cancelStreaming()

        let session = await dependencies.chatSessionStore.session(for: conversation.id)
        let liveDriver = LiveChatSessionDriver(session: session)
        // If the conversation isn't on disk yet (a fresh "New Chat" tap
        // or a first-launch empty DB), wrap the driver so persistence
        // happens lazily — the first `send` writes the
        // `ConversationRecord` *then* forwards the message. An unused
        // draft never touches disk.
        let conversationRepo = dependencies.conversationRepository
        let isDraft = ((try? await conversationRepo.fetch(id: conversation.id)) == nil)
        let conversationCopy = conversation
        let driver: any ChatSessionDriver
        if isDraft {
            driver = LazyConversationDriver(
                inner: liveDriver,
                ensureSaved: {
                    try? await conversationRepo.save(conversationCopy)
                },
                onPersisted: { [weak sidebar = sidebarViewModel] in
                    // Promote the draft row to a real DB-backed row in
                    // the sidebar. `refresh()` self-clears the draft
                    // pointer when it sees the row in the DB list.
                    await sidebar?.refresh()
                }
            )
        } else {
            driver = liveDriver
        }
        let providers = await dependencies.llmProviderRegistry.allProviders()
        let providerModels = providers.flatMap(\.supportedModels)
        let verbosity = settingsViewModel?.settings.defaultVerbosity ?? .verbose
        let titleGenerator = TitleGenerator(llmProviderRegistry: dependencies.llmProviderRegistry)
        let voice = VoiceInputController(service: SpeechRecognizerVoiceInputService())
        let newModel = ChatScreenViewModel(
            conversationId: conversation.id,
            conversationTitle: conversation.title ?? "New chat",
            driver: driver,
            messageRepository: dependencies.messageRepository,
            toolCallRepository: dependencies.toolCallRepository,
            checkpointRepository: dependencies.checkpointRepository,
            availableModels: providerModels,
            selectedModelId: providerModels.first?.id,
            verbosity: verbosity,
            conversationRepository: dependencies.conversationRepository,
            titleGenerator: titleGenerator,
            voice: voice
        )
        let registry = dependencies.llmProviderRegistry
        newModel.onModelSelected = { modelId in
            Task { await activateProvider(matching: modelId, in: registry) }
        }
        // When the auto-titler lands, repaint the sidebar so the row's
        // "New chat" placeholder flips to the real title without waiting
        // for the next drawer open.
        newModel.onTitleGenerated = { [weak sidebar = sidebarViewModel] _ in
            Task { await sidebar?.refresh() }
        }
        // Mirror the picker's initial pick so the registry's "active"
        // matches what the user sees in the composer pill — without this
        // the chat would route to whatever was first registered, which
        // isn't necessarily what the picker shows after the user adds a
        // second model.
        if let firstId = providerModels.first?.id {
            await activateProvider(matching: firstId, in: registry)
        }
        // Pre-load the transcript so the first render of the swapped-in
        // view model already shows the messages instead of flashing the
        // empty state. ChatScreen's `.task(id: conversationId)` still
        // re-fires for any future swap.
        await newModel.load()
        viewModel = newModel
        activeConversationId = conversation.id
        sidebarViewModel?.activeConversationId = conversation.id
    }

    /// Find the registered provider whose `supportedModels` include
    /// `modelId` and promote it to active. The picker uses the upstream
    /// model identifier (e.g. `claude-opus-4-7`), not the record UUID,
    /// so we have to scan rather than `setActive(id: modelId)` directly.
    private func activateProvider(
        matching modelId: String,
        in registry: LLMProviderRegistry
    ) async {
        let providers = await registry.allProviders()
        guard let match = providers.first(where: {
            $0.supportedModels.contains { $0.id == modelId }
        }) else { return }
        try? await registry.setActive(id: match.id)
    }

    /// Refresh the chat composer's model list after the user
    /// adds/edits/deletes a model in Settings. Re-pulls from the
    /// registry (which `SettingsViewModel` already updated during the
    /// save) and pushes the new list into the live chat view model so
    /// the picker repaints without losing the transcript. Also re-runs
    /// the active-provider promotion so the picker's current selection
    /// matches the registry.
    private func refreshAvailableModels() async {
        let providers = await dependencies.llmProviderRegistry.allProviders()
        let models = providers.flatMap(\.supportedModels)
        viewModel?.setAvailableModels(models)
        if let pickedId = viewModel?.selectedModelId {
            await activateProvider(matching: pickedId, in: dependencies.llmProviderRegistry)
        }
    }

    private func selectConversation(id: String) async {
        sidebarOpen = false
        guard id != activeConversationId else { return }
        do {
            guard let row = try await dependencies.conversationRepository.fetch(id: id) else { return }
            // Picking an existing chat drops any in-memory draft.
            sidebarViewModel?.draftConversation = nil
            await rebuildChatViewModel(for: row)
            await sidebarViewModel?.refresh()
        } catch {
            bootstrapError = "Could not open chat: \(error.localizedDescription)"
        }
    }

    private func startNewChat() async {
        sidebarOpen = false
        let now = Date()
        // Construct an in-memory draft. Persistence is deferred to the
        // first send (`LazyConversationDriver` writes the record then,
        // and the sidebar self-promotes the draft row to a real one).
        let row = ConversationRecord(
            id: UUID().uuidString,
            title: "New chat",
            createdAt: now,
            updatedAt: now
        )
        sidebarViewModel?.draftConversation = row
        await rebuildChatViewModel(for: row)
    }

    /// Returns the conversation to load on launch — always a fresh
    /// in-memory draft so the user starts every session on a clean
    /// "New chat" surface. Existing persisted rows remain accessible
    /// from the sidebar drawer. The draft only hits disk if the user
    /// actually sends a message (same lazy-persist path as `startNewChat`).
    private func ensureConversation() -> ConversationRecord {
        let now = Date()
        return ConversationRecord(
            id: UUID().uuidString,
            title: "New chat",
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - Previews

#Preview("loading") {
    ContentView(state: .loading)
}

#Preview("failed") {
    ContentView(state: .failed("could not open chat.sqlite"))
}
