import Chat
import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App-level shell content. Renders `AppShell` once the bootstrap
/// dependency graph is `.ready`, a transient progress pane during
/// `.loading`, and an inline error pane when the bootstrap fails.
///
/// `AppShell` owns the chat surface, the applet backdrop, the
/// hamburger chrome, the sidebar drawer, and the settings sheet.
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
                AppShell(dependencies: dependencies)
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

// MARK: - App shell

/// Hosts the active mini-app's backdrop, the always-on-top chat overlay,
/// the shell-level hamburger chrome, and the sidebar + settings drawers.
///
/// On launch the shell registers the four backdrop applets (Todo, Recipes,
/// Bible, Finance) with an `AppletRegistry`. Chat is *not* a registered
/// applet — it's the host surface that overlays everything else.
/// One backdrop applet is always selected so dragging the chat down
/// reveals a real applet behind it. `init` seeds `AppletRegistry.activeID`
/// from `@AppStorage("shell.activeAppletID")` (defaulting to Todo on first
/// ever launch), and `onSelectApplet` writes the user's pick back so the
/// selection survives relaunches. If the persisted ID doesn't match any
/// registered applet (e.g. a future build removed one), the shell falls
/// back to the first registered applet.
///
/// The shell also owns the sidebar drawer and settings sheet visibility
/// bindings, and the per-conversation view-model rebuild path the chat
/// surface needs when the user picks a different chat from the sidebar.
struct AppShell: View {
    let dependencies: AppDependencies

    @State private var registry: AppletRegistry
    /// The current chat presentation shape. Starts in `.expanded` so the
    /// app launches into a full-screen chat surface — the backdrop applet
    /// (seeded from persisted state) sits behind, ready to reveal when
    /// the user drags down. Mutates in response to (a) the user dragging
    /// the chat surface's drag handle, (b) tapping the minimized pill,
    /// (c) tapping the dimmed applet backdrop in semi-expanded (→ minimized),
    /// (d) selecting an applet from the sidebar (→ minimized), or (e)
    /// selecting an existing chat / "New Chat" from the sidebar (→ expanded).
    @State private var chatState: ChatPresentationState = .expanded
    @State private var viewModel: ChatScreenViewModel?
    @State private var sidebarViewModel: SidebarViewModel?
    @State private var settingsViewModel: SettingsViewModel?
    @State private var bootstrapError: String?
    @State private var theme: SuperTheme = .make(.light)
    @State private var appearance: ChatAppearance = .default
    @State private var sidebarOpen: Bool = false
    @State private var settingsOpen: Bool = false
    @State private var activeConversationId: String?
    /// Set the moment `ensureViewModel` enters its critical section so a
    /// re-fired `.task` (scene refresh, identity change) can't race a
    /// second bootstrap before the first finishes. Safe to read/write
    /// without coordination because `.task` runs on the main actor.
    @State private var bootstrapStarted = false
    /// `UserDefaults` key for the persisted backdrop applet ID. Referenced
    /// from both the bootstrap read in `init` and the write-back in
    /// `onSelectApplet` — the two must agree or persistence silently breaks.
    private static let activeAppletStorageKey = "shell.activeAppletID"

    /// Resolves the initial backdrop applet from persisted state and builds
    /// the registry. Reads `UserDefaults` directly because `@State` is not
    /// yet wired up at `init` time; falls back to the first registered
    /// applet when no persisted ID exists or the ID no longer matches.
    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let applets: [any MiniApplet] = [
            ToDoPlaceholderApplet(),
            RecipesPlaceholderApplet(),
            BiblePlaceholderApplet(),
            FinancePlaceholderApplet(),
        ]
        // Read UserDefaults directly because `@State` initializers run
        // before `@AppStorage` is wired up. The fallback chain keeps the
        // invariant that some backdrop is always selected: persisted ID
        // if it still matches a registered applet, else the first applet.
        let storedID = UserDefaults.standard.string(forKey: Self.activeAppletStorageKey)
        let resolvedID = applets.first(where: { $0.appletID == storedID })?.appletID
            ?? applets.first?.appletID
        _registry = State(initialValue: AppletRegistry(
            applets: applets,
            initialActiveID: resolvedID
        ))
    }

    private var appInfo: SuperAppInfo { .fromBundle() }

    /// Honoured by the chat-overlay container's spring and by the
    /// backdrop's opacity transition. Reading it here so the sidebar's
    /// programmatic state flip uses the right animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opacity applied to the applet backdrop based on the current chat
    /// presentation. `.semiExpanded` dims the backdrop to 0.65 per the
    /// 2026-05-13 design; other states leave it at 1.0. In `.expanded`
    /// the chat overlay is opaque so this value is effectively unused.
    private var backdropOpacity: Double {
        switch chatState {
        case .semiExpanded: 0.65
        case .expanded, .minimized: 1.0
        }
    }

    var body: some View {
        ZStack {
            // Backdrop: the active applet's rootView. Dimmed to 0.65 in
            // semi-expanded so the chat panel reads against a faded
            // applet behind it; full opacity in minimized; effectively
            // hidden behind the opaque expanded chat (no opacity tweak
            // needed because the chat covers it).
            if let activeApplet = registry.activeApplet {
                activeApplet.rootView()
                    .ignoresSafeArea()
                    .opacity(backdropOpacity)
                    // Backdrop interactivity:
                    //   .expanded     — chat covers the screen; backdrop
                    //                   is hidden behind it, no hit
                    //                   testing needed.
                    //   .semiExpanded — backdrop is dimmed and the
                    //                   transparent overlay below
                    //                   catches taps to minimize the
                    //                   chat (iOS sheet "tap-dim-to-
                    //                   dismiss" parity).
                    //   .minimized    — backdrop owns the screen; the
                    //                   user is working inside the
                    //                   applet, so hit testing must be
                    //                   enabled for the applet's own UI
                    //                   to respond. No overlay attached
                    //                   so applet taps pass through.
                    .allowsHitTesting(chatState != .expanded)
                    .overlay {
                        if chatState == .semiExpanded {
                            // Transparent tap-target sits above the
                            // dimmed applet only while semi-expanded.
                            // An always-present `.onTapGesture` would
                            // consume applet taps in `.minimized` too,
                            // even though it would no-op there.
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(ChatOverlayAnimation.transition(reduceMotion: reduceMotion)) {
                                        chatState = .minimized
                                    }
                                }
                        }
                    }
                    .animation(
                        ChatOverlayAnimation.transition(reduceMotion: reduceMotion),
                        value: chatState
                    )
            }

            // Chat overlay. Always rendered now (even when a placeholder
            // applet is active) — the container picks its shape from
            // `chatState`: full-screen in `.expanded`, floating panel in
            // `.semiExpanded`, full-width pill at the bottom in
            // `.minimized`. The container itself handles the drag-snap
            // transitions via the drag handle.
            if let viewModel {
                ChatOverlayContainer(
                    state: $chatState,
                    viewModel: viewModel,
                    onManageModels: { openSettings(initialPane: .models) },
                    onAddModelRequested: { openSettings(initialPane: .modelDetail(id: nil)) }
                )
                .superTheme(theme)
                .chatAppearance(appearance)
            } else if let bootstrapError {
                FailureScreen(message: bootstrapError)
            } else {
                LoadingScreen()
            }

            // Shell chrome: hamburger at top-left, outside the chat surface.
            // Aligned to topLeading inside the safe area so the status bar
            // doesn't sit on top of it.
            VStack {
                HStack {
                    FixedHamburgerButton(onTap: openSidebar)
                        .superTheme(theme)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.top, 4)

            if let sidebarViewModel {
                SidebarDrawer(
                    isPresented: $sidebarOpen,
                    viewModel: sidebarViewModel,
                    appInfo: appInfo,
                    userInitials: "BW",
                    userName: "Brian Wang",
                    applets: registry.applets,
                    activeAppletID: registry.activeID,
                    onSelectConversation: { id in
                        Task { await selectConversation(id: id) }
                    },
                    onNewChat: {
                        Task { await startNewChat() }
                    },
                    onOpenSettings: {
                        openSettings()
                    },
                    onSelectApplet: { appletID in
                        registry.activeID = appletID
                        UserDefaults.standard.set(appletID, forKey: Self.activeAppletStorageKey)
                        // Selecting any backdrop applet from the sidebar
                        // collapses the chat to minimized so the user
                        // can interact with the applet. They can drag
                        // the pill up to climb back to semi/expanded.
                        withAnimation(ChatOverlayAnimation.transition(reduceMotion: reduceMotion)) {
                            chatState = .minimized
                        }
                    }
                )
                .superTheme(theme)
                .chatAppearance(appearance)
            }

            if let settingsViewModel {
                SettingsSheet(
                    isPresented: $settingsOpen,
                    viewModel: settingsViewModel
                )
                .superTheme(theme)
                .chatAppearance(appearance)
            }
        }
        .task {
            await ensureViewModel()
        }
        // Narrow observers instead of one broad one on `settings`
        // so unrelated mutations (system prompt, verbosity, auto-compact
        // threshold) don't churn the host's render state — only the
        // appearance-relevant fields fire a refresh.
        .onChange(of: settingsViewModel?.settings.themeId) { _, newId in
            if let newId { theme = .make(newId) }
        }
        .onChange(of: settingsViewModel?.settings.fontScale) { _, newScale in
            guard let newScale else { return }
            appearance = ChatAppearance(fontScale: newScale)
        }
        .onChange(of: settingsViewModel?.models) { _, _ in
            // Refresh the composer's model picker whenever Settings adds,
            // edits, or deletes a model — `SettingsViewModel` already
            // re-registered/unregistered the matching `LLMProvider` with
            // the registry, so the picker just needs to re-pull.
            Task { await refreshAvailableModels() }
        }
        .onChange(of: settingsViewModel?.settings.defaultVerbosity) { _, newValue in
            // The chat view model is constructed per-conversation, so without
            // an explicit push here a settings flip would only take effect
            // when the user opens the next chat.
            viewModel?.applyExternalVerbosity(newValue)
        }
    }

    private func openSidebar() {
        guard let sidebarViewModel else { return }
        // Mirror the keyboard-dismiss the old in-`ChatScreen` hamburger
        // did. Opening the sidebar with the composer focused would
        // otherwise leave the keyboard up behind the drawer.
        dismissKeyboard()
        sidebarOpen = true
        Task { await sidebarViewModel.refresh() }
    }

    /// Resign first responder so the on-screen keyboard tears down
    /// before a chrome transition. Mirrors `ChatScreen.dismissKeyboard()`
    /// — the UIKit dispatch is the load-bearing piece on iOS 26.x where
    /// flipping `@FocusState` from a sibling isn't always enough to
    /// hide the keyboard.
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
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
                autoCompactPolicyReceiver: dependencies.chatSessionStore,
                llmProviderRegistry: dependencies.llmProviderRegistry,
                httpClient: URLSessionHTTPClient()
            )
            await settings.load()
            settingsViewModel = settings
            theme = .make(settings.settings.themeId)
            appearance = ChatAppearance(fontScale: settings.settings.fontScale)
        } catch {
            bootstrapError = "Could not open chat: \(error.localizedDescription)"
        }
    }

    private func rebuildChatViewModel(for conversation: ConversationRecord) async {
        // Detach (don't cancel) the outgoing view model. Its iteration
        // task stops draining events so it can deinit promptly, but the
        // underlying `ChatSession` (owned by `ChatSessionStore`) keeps
        // streaming the turn to completion. Switching back will create a
        // new view model whose `load()` re-attaches via `subscribe()`.
        viewModel?.detachFromLiveTurn()

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
        // Selecting a chat is an intent to focus on chat — snap the
        // overlay to expanded if the user came from minimized/semi over
        // an applet backdrop.
        withAnimation(ChatOverlayAnimation.transition(reduceMotion: reduceMotion)) {
            chatState = .expanded
        }
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
        // New Chat is an intent to focus on chat — snap to expanded.
        withAnimation(ChatOverlayAnimation.transition(reduceMotion: reduceMotion)) {
            chatState = .expanded
        }
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
