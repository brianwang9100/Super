import Chat
import Core
import GRDBQuery
import os
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private let appShellLog = Logger(subsystem: "com.brianwang.Super", category: "app-shell")

/// Hosts the active applet behind Chat, with shared sidebar and settings chrome.
struct AppShell: View {
    /// Shared by both bootstraps; bundle-specific UserDefaults keep target selections separate.
    static let activeAppletStorageKey: String = "shell.activeAppletID"

    let dependencies: AppShellDependencies

    @State private var registry: AppletRegistry
    /// Settled anchor; live drag progress is tracked separately below.
    @State private var chatState: ChatPresentationState
    /// Live overlay progress: 0 = pill, 1 = full screen. Seeded before preference delivery
    /// to prevent a first-frame dim mismatch.
    @State private var chatProgress: Double
    /// Geometry-dependent semi-expanded progress; 0.52 is the fallback before preference delivery.
    @State private var chatSemiProgress: Double = 0.52
    @State private var viewModel: ChatScreenViewModel?
    /// Buffers references across conversation/view-model changes. Attaches idempotently in `.task`.
    @State private var referenceInbox = ChatReferenceInbox()
    @State private var sidebarViewModel: SidebarViewModel?
    @State private var settingsViewModel: SettingsViewModel?
    @State private var bootstrapError: String?
    @State private var theme: SuperTheme = .make(.vellumLight)
    @State private var appearance: ChatAppearance = .default
    @State private var typography: SuperTypography = .make(SuperTypography.Identifier.serif)
    @State private var sidebarOpen: Bool = false
    @State private var settingsOpen: Bool = false
    /// Reset on applet switches and when Chat leaves its minimized state.
    @State private var shellChromeVisible = true
    @State private var activeConversationId: String?
    /// Shared with the composer so chrome transitions clear actual focus. UIKit dismissal
    /// alone leaves SwiftUI focused and makes the keyboard reappear on expansion.
    @FocusState private var composerIsFocused: Bool
    /// Set before the first suspension to prevent duplicate bootstrap tasks on the main actor.
    @State private var bootstrapStarted = false
    /// Dispatch through body observation so navigation reads fresh environment values.
    /// Calling directly from the bus task would freeze Reduce Motion in its captured `self`.
    @State private var pendingNavigation: PendingNavigation?

    /// Seed chat state and progress together so the first frame matches the target launch policy.
    init(dependencies: AppShellDependencies) {
        self.dependencies = dependencies
        _registry = State(initialValue: dependencies.appletRegistry)
        let initialChatState = dependencies.launchBehavior.initialChatState
        _chatState = State(initialValue: initialChatState)
        // Keep this switch exhaustive when new presentation states are added.
        // Semi-expanded launch requires geometry; see AppShellLaunchBehavior.
        _chatProgress = State(initialValue: {
            switch initialChatState {
            case .expanded: 1.0
            case .minimized: 0.0
            case .semiExpanded:
                preconditionFailure(
                    "AppShellLaunchBehavior does not support .semiExpanded today — see App/Shell/AppShellLaunchBehavior.swift."
                )
            }
        }())
        // Attach the inbox in `.task`, not init, to avoid ghost subscriptions on parent re-renders.
    }

    private var appInfo: SuperAppInfo { .fromBundle() }

    private var composerHidden: Bool {
        !shellChromeVisible && chatState == .minimized
    }

    /// Clears the pill height plus the bottom safe area.
    private static let composerHideDistance: CGFloat =
        ChatPresentationState.minimizedBaseHeight + 140

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Separate bodies limit work when composer focus invalidates the shell.
        ZStack {
            BackdropLayer(
                activeApplet: registry.activeApplet,
                activeAppletID: registry.activeID,
                theme: theme,
                appearance: appearance,
                typography: typography,
                chatState: chatState,
                chatProgress: chatProgress,
                chatSemiProgress: chatSemiProgress,
                onBackdropTap: {
                    dismissKeyboard()
                    withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
                        chatState = .minimized
                    }
                },
                reduceMotion: reduceMotion
            )
            // Skip rebuilding the applet tree on composer focus changes; see BackdropLayer.==.
            .equatable()
            // Stable store identity preserves the backdrop equality check.
            .composerAccessoryStore(dependencies.composerAccessoryStore)
            ChatLayer(
                viewModel: viewModel,
                bootstrapError: bootstrapError,
                chatState: $chatState,
                composerIsFocused: $composerIsFocused,
                theme: theme,
                appearance: appearance,
                typography: typography,
                onManageModels: { openSettings(rootedAt: .models) },
                onAddModelRequested: { openSettings(pushing: .modelDetail(id: nil)) },
                onProgressChange: { chatProgress = $0 },
                onSemiProgressChange: { chatSemiProgress = $0 }
            )
            .environment(
                \.appletSuggestedChatActions,
                SuggestedChatAction.merged(registry.applets.map(\.suggestedChatActions))
            )
            .offset(y: composerHidden ? Self.composerHideDistance : 0)
            .animation(
                SuperMotion.chrome(hiding: composerHidden, reduceMotion: reduceMotion),
                value: composerHidden
            )
            // Off-screen offsets do not remove controls from VoiceOver.
            .accessibilityHidden(composerHidden)
            // A sibling of ChatLayer so accessories stay visible when the pill slides off-screen.
            if let composerAccessoryStore = dependencies.composerAccessoryStore {
                ComposerAccessoryLayer(
                    store: composerAccessoryStore,
                    chatProgress: chatProgress,
                    composerHidden: composerHidden,
                    theme: theme,
                    typography: typography,
                    reduceMotion: reduceMotion
                )
            }
            HamburgerLayer(theme: theme, chromeVisible: shellChromeVisible, onTap: openSidebar)
            SidebarLayer(
                sidebarOpen: $sidebarOpen,
                sidebarViewModel: sidebarViewModel,
                appInfo: appInfo,
                applets: registry.applets,
                activeAppletID: registry.activeID,
                theme: theme,
                appearance: appearance,
                typography: typography,
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
                    dismissKeyboard()
                    registry.activeID = appletID
                    UserDefaults.standard.set(appletID, forKey: Self.activeAppletStorageKey)
                    withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
                        chatState = .minimized
                    }
                },
                onSeeAllChats: {
                    dismissKeyboard()
                    registry.activeID = ChatsApplet.appletID
                    UserDefaults.standard.set(ChatsApplet.appletID, forKey: Self.activeAppletStorageKey)
                    withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
                        chatState = .minimized
                    }
                }
            )
        }
        // Reset navigation after either dismissal path finishes animating.
        .sheet(isPresented: $settingsOpen, onDismiss: { settingsViewModel?.popToRoot() }) {
            SettingsLayer(
                settingsOpen: $settingsOpen,
                settingsViewModel: settingsViewModel,
                // Delay database-context creation until Settings is ready; its memory query needs chat.sqlite.
                makeDatabaseContext: { .readOnly { dependencies.chatDatabase.queue } },
                theme: theme,
                appearance: appearance,
                typography: typography
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(theme.background)
        }
        .task {
            await ensureViewModel()
        }
        // Observe appearance fields separately so unrelated settings do not invalidate render state.
        .onChange(of: settingsViewModel?.settings.themeId) { _, newId in
            if let newId { theme = .make(newId) }
        }
        .onChange(of: settingsViewModel?.settings.fontScale) { _, newScale in
            guard let newScale, let settingsViewModel else { return }
            appearance = ChatAppearance(fontScale: newScale)
            typography = .make(settingsViewModel.settings.typographyID, fontScale: newScale)
        }
        .onChange(of: settingsViewModel?.settings.typographyID) { _, newID in
            // Read settings directly to avoid depending on delivery order of simultaneous field changes.
            guard let newID, let settingsViewModel else { return }
            typography = .make(newID, fontScale: settingsViewModel.settings.fontScale)
        }
        .onChange(of: settingsViewModel?.models) { _, _ in
            Task { await refreshAvailableModels() }
        }
        .onChange(of: settingsViewModel?.settings.defaultVerbosity) { _, newValue in
            // Push into the live model so the setting applies before the next conversation switch.
            viewModel?.applyExternalVerbosity(newValue)
        }
        // One observable combines presence and intent to avoid racing two chrome animations.
        .onChange(of: referenceInbox.pendingAttention) { _, _ in
            guard let request = referenceInbox.consumeAttention() else { return }
            Task { await handleComposerAttention(isNewChat: request.startNew) }
        }
        // On iOS 26, clearing the child FocusState binding while disabling the field can fail.
        // Clear the shell owner too: chatState covers settled collapse and progress covers mid-drag.
        // This observer runs one preference tick after the child; both dismissals are idempotent.
        .onChange(of: chatState) { _, newState in
            if newState == .minimized {
                dismissKeyboard()
            } else {
                shellChromeVisible = true
            }
        }
        // One applet must not leave another applet's chrome hidden.
        .onChange(of: registry.activeID) { _, _ in
            shellChromeVisible = true
        }
        .onChange(of: chatProgress) { oldValue, newValue in
            if ChatPresentationState.crossedBelowEditorThreshold(from: oldValue, to: newValue) {
                dismissKeyboard()
            }
        }
        // Consume from the current body so navigation uses fresh environment values.
        .onChange(of: pendingNavigation) { _, newValue in
            guard let request = newValue else { return }
            pendingNavigation = nil
            switch request {
            case .openConversation(let id):
                Task { await selectConversation(id: id) }
            case .newConversation:
                Task { await startNewChat() }
            case .openApplet(let id):
                // Keep collapse in this onChange transaction; a Task defers it and loses the animation.
                selectApplet(id: id)
            }
        }
        .environment(\.superEventBus, dependencies.eventBus)
        .hapticsEngine(dependencies.hapticsEngine)
        // External deep links use the same event-bus route as transcript links.
        .onOpenURL { url in
            guard let link = BibleDeepLink(url: url) else { return }
            let eventBus = dependencies.eventBus
            Task { await eventBus.publish(.openRecord(reference: link.recordReference)) }
        }
    }

    /// Shows the requested applet and collapses Chat; unknown applet IDs are ignored.
    @MainActor
    private func selectApplet(id: String) {
        guard registry.applets.contains(where: { $0.appletID == id }) else {
            appShellLog.warning("openRecord for unregistered applet \(id, privacy: .public) — dropped")
            return
        }
        dismissKeyboard()
        registry.activeID = id
        UserDefaults.standard.set(id, forKey: Self.activeAppletStorageKey)
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
            chatState = .minimized
        }
    }

    private func openSidebar() {
        guard let sidebarViewModel else { return }
        dependencies.hapticsEngine.play(.selection)
        dismissKeyboard()
        sidebarOpen = true
        // Native sheets cover this in-view drawer. Start its animation before the async
        // dismissal broadcast so the drawer responds immediately.
        let eventBus = dependencies.eventBus
        Task {
            await eventBus.publish(.sidebarOpened)
            await sidebarViewModel.refresh()
        }
    }

    /// Clear focus to prevent re-focusing on expansion, then resign UIKit first responder.
    /// iOS 26 can leave the keyboard visible when only FocusState is cleared.
    private func dismissKeyboard() {
        composerIsFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }

    /// The root pane closes the sheet; a pushed pane navigates back to that root.
    /// Set the root on every presentation to avoid carrying over a previous route.
    private func openSettings(
        rootedAt rootPane: SettingsSheet.Pane = .root,
        pushing pushedPane: SettingsSheet.Pane? = nil
    ) {
        guard let settingsViewModel else { return }
        // Seed navigation before presentation so the sheet opens on the requested pane.
        settingsViewModel.rootPane = rootPane
        if let pushedPane {
            settingsViewModel.openPane(pushedPane)
        }
        settingsOpen = true
    }

    private func ensureViewModel() async {
        guard !bootstrapStarted else { return }
        bootstrapStarted = true
        // Subscribe before mounting a composer so early references are buffered.
        await referenceInbox.attach(to: dependencies.eventBus)

        // Keep routing alive for the app session. PendingNavigation lets body observation
        // dispatch with fresh environment values instead of this task's captured `self`.
        let eventBus = dependencies.eventBus
        Task { [self] in
            for await event in await eventBus.events() {
                switch event {
                case .openConversationRequested(let id):
                    pendingNavigation = .openConversation(id: id)
                case .newConversationRequested:
                    pendingNavigation = .newConversation
                case .recordAddedToChat:
                    // ChatReferenceInbox owns this handoff; do not route it twice.
                    break
                case .openRecord(let reference):
                    // The applet subscriber navigates within the applet; the shell only exposes its backdrop.
                    pendingNavigation = .openApplet(id: reference.appletID)
                case .bibleAnnotateRequested, .bibleAnnotateCompleted:
                    break
                case .credentialChanged: break
                case .sidebarOpened:
                    break
                case .shellChromeVisibilityRequested(let visible):
                    // Chrome views animate using their current Reduce Motion environment; this task
                    // captures an older environment, so do not animate here.
                    shellChromeVisible = visible
                }
            }
        }
        let conversation = ensureConversation()
        let isDraft = ((try? await dependencies.conversationRepository.fetch(id: conversation.id)) == nil)
        // Build the sidebar first so lazy-persist and auto-title callbacks can capture it.
        let sidebar = SidebarViewModel(
            conversationRepository: dependencies.conversationRepository,
            sessionStore: dependencies.chatSessionStore,
            activeConversationId: conversation.id
        )
        sidebarViewModel = sidebar
        if isDraft {
            sidebar.draftConversation = conversation
        }
        // settings.load() must precede rebuildChatViewModel — provides lastSelectedModelId, verbosity, and theme.
        let settings = SettingsViewModel(
            appInfo: appInfo,
            settingRepository: dependencies.settingRepository,
            modelRepository: dependencies.modelConfigurationRepository,
            conversationRepository: dependencies.conversationRepository,
            toolRegistry: dependencies.toolRegistry,
            userPersonalizationReceiver: dependencies.chatSessionStore,
            autoCompactPolicyReceiver: dependencies.chatSessionStore,
            webSearchPolicyReceiver: dependencies.chatSessionStore,
            hapticsEngine: dependencies.hapticsEngine,
            messageRepository: dependencies.messageRepository,
            toolCallRepository: dependencies.toolCallRepository,
            // Optional for fixtures, required here for memory editing and deletion.
            memoryRepository: dependencies.memoryRepository,
            llmProviderRegistry: dependencies.llmProviderRegistry,
            httpClient: URLSessionHTTPClient(),
            // Reuse boot-time availability so a mid-session Apple Intelligence toggle cannot
            // make Settings disagree with the seeder and provider hydrator.
            appleFoundationAvailability: dependencies.appleFoundationAvailability,
            audioSetup: dependencies.providerAudioSetup,
            eventBus: dependencies.eventBus
        )
        await settings.load()
        settingsViewModel = settings
        // Apply persisted haptics before any interaction; Settings owns subsequent toggles.
        dependencies.hapticsEngine.setEnabled(settings.settings.hapticsEnabled)
        theme = .make(settings.settings.themeId)
        appearance = ChatAppearance(fontScale: settings.settings.fontScale)
        typography = .make(settings.settings.typographyID, fontScale: settings.settings.fontScale)

        await rebuildChatViewModel(for: conversation)
        await sidebar.refresh()
    }

    private func rebuildChatViewModel(for conversation: ConversationRecord) async {
        // Detach only the view model. The stored session keeps streaming; a new model
        // reattaches when the conversation is reopened.
        viewModel?.detachFromLiveTurn()

        let session = await dependencies.chatSessionStore.session(for: conversation.id)
        let liveDriver = LiveChatSessionDriver(session: session)
        // Persist new drafts on first send only; unused drafts must never reach disk.
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
                    // Refresh promotes the now-persisted draft into the sidebar's database rows.
                    await sidebar?.refresh()
                }
            )
        } else {
            driver = liveDriver
        }
        let providers = await dependencies.llmProviderRegistry.allProviders()
        let providerModels = SelectableModel.from(providers: providers)
        let verbosity = settingsViewModel?.settings.defaultVerbosity ?? .verbose
        let titleGenerator = TitleGenerator(
            llmProviderRegistry: dependencies.llmProviderRegistry,
            settingsStore: ChatSettingsStore(repository: dependencies.settingRepository)
        )
        let voice = VoiceInputController(service: SpeechRecognizerVoiceInputService(), audioActivity: dependencies.audioActivity)
        // Use the persisted model id so the picker survives relaunch; stale ids fall back to first available.
        let persistedModelId = settingsViewModel?.settings.lastSelectedModelId
        let initialModelId = ChatScreenViewModel.resolveInitialModelId(
            persisted: persistedModelId,
            available: providerModels
        )
        // Compose tool labels here because Chat cannot import other applets' descriptors.
        let registrations = await dependencies.toolRegistry.allRegistrations()
        let toolDisplayNames = registrations
            .reduce(into: [String: String]()) { map, registration in
                map[registration.tool.name] = registration.tool.displayName ?? registration.tool.name
            }
        // Suggestions use a minimal capability prompt, never the conversation system prompt.
        let suggestionCapabilities = SuggestionCapabilities.compact(
            from: registrations.filter(\.isEnabled).map(\.tool)
        )
        let suggestionsProvider: any ChatSuggestionsProvider =
            dependencies.appleFoundationAvailability.isAvailable
            ? AppleFoundationChatSuggestionsProvider(
                provider: AppleFoundationLLMProvider(
                    id: "afm-suggestions",
                    availability: dependencies.appleFoundationAvailability,
                    toolRegistry: nil
                ),
                capabilities: suggestionCapabilities
            )
            : StaticChatSuggestionsProvider()
        let newModel = ChatScreenViewModel(
            conversationId: conversation.id,
            conversationTitle: conversation.title ?? "New chat",
            driver: driver,
            messageRepository: dependencies.messageRepository,
            toolCallRepository: dependencies.toolCallRepository,
            checkpointRepository: dependencies.checkpointRepository,
            availableModels: providerModels,
            selectedModelId: initialModelId,
            verbosity: verbosity,
            conversationRepository: dependencies.conversationRepository,
            titleGenerator: titleGenerator,
            voice: voice,
            referenceInbox: referenceInbox,
            toolDisplayNames: toolDisplayNames,
            suggestionsProvider: suggestionsProvider,
            hapticsEngine: dependencies.hapticsEngine
        )
        let registry = dependencies.llmProviderRegistry
        // Fire-and-forget: persisting the pick is best-effort; a dropped write falls back to first-available next launch.
        newModel.onModelSelected = { [weak settings = settingsViewModel] recordId in
            Task {
                try? await registry.setActive(id: recordId)
                await settings?.setLastSelectedModelId(recordId)
            }
        }
        newModel.onTitleGenerated = { [weak sidebar = sidebarViewModel] _ in
            Task { await sidebar?.refresh() }
        }
        // Persist the resolved record ID to repair legacy model IDs as well as stale selections.
        if let id = initialModelId {
            try? await registry.setActive(id: id)
            if id != persistedModelId {
                await settingsViewModel?.setLastSelectedModelId(id)
            }
        }
        // Load before swapping models to avoid flashing the empty transcript.
        await newModel.load()
        viewModel = newModel
        activeConversationId = conversation.id
        sidebarViewModel?.activeConversationId = conversation.id
    }

    /// Refreshes picker choices without rebuilding the transcript and reasserts its active provider.
    private func refreshAvailableModels() async {
        let providers = await dependencies.llmProviderRegistry.allProviders()
        viewModel?.setAvailableModels(SelectableModel.from(providers: providers))
        if let recordId = viewModel?.selectedModelId {
            try? await dependencies.llmProviderRegistry.setActive(id: recordId)
        }
    }

    private func selectConversation(id: String) async {
        sidebarOpen = false
        dismissKeyboard()
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
            chatState = .expanded
        }
        guard id != activeConversationId else { return }
        do {
            guard let row = try await dependencies.conversationRepository.fetch(id: id) else { return }
            sidebarViewModel?.draftConversation = nil
            await rebuildChatViewModel(for: row)
            await sidebarViewModel?.refresh()
        } catch {
            bootstrapError = "Could not open chat: \(error.localizedDescription)"
        }
    }

    /// Opens a draft; handoffs use semi-expanded so the source applet remains visible.
    private func startNewChat(targetChatState: ChatPresentationState = .expanded) async {
        sidebarOpen = false
        dismissKeyboard()
        let now = Date()
        let row = ConversationRecord(
            id: UUID().uuidString,
            title: "New chat",
            createdAt: now,
            updatedAt: now
        )
        sidebarViewModel?.draftConversation = row
        // Rebuild before expanding so the transition never shows the previous conversation.
        await rebuildChatViewModel(for: row)
        await animateChatState(to: targetChatState)
        composerIsFocused = true
    }

    /// Waits for logical completion before focus can trigger keyboard avoidance; focusing
    /// mid-animation measures an in-flight composer frame and disrupts the overlay spring.
    private func animateChatState(to target: ChatPresentationState) async {
        guard chatState != target else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            withAnimation(
                SuperMotion.transition(reduceMotion: reduceMotion),
                completionCriteria: .logicallyComplete
            ) {
                chatState = target
            } completion: {
                cont.resume()
            }
        }
    }

    /// Reveals a handed-off reference without lowering an existing chat anchor, then focuses
    /// after the transition settles to avoid the keyboard-avoidance race.
    private func handleComposerAttention(isNewChat: Bool) async {
        if isNewChat {
            let target: ChatPresentationState = chatState == .expanded ? .expanded : .semiExpanded
            await startNewChat(targetChatState: target)
            return
        }
        if chatState == .minimized {
            await animateChatState(to: .semiExpanded)
        }
        composerIsFocused = true
    }

    /// Launch into a fresh draft; save only on first send. Saved chats remain in the sidebar.
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

/// Passes bus-task navigation to the body observer, which reads current environment values.
private enum PendingNavigation: Equatable {
    case openConversation(id: String)
    case newConversation
    case openApplet(id: String)
}

// MARK: - Shell layers

/// Gates backdrop work on render inputs so composer focus changes do not rebuild the applet.
/// SwiftUI diffs on the main actor; the isolated conformance matches the view's isolation.
private struct BackdropLayer: View, @MainActor Equatable {
    /// Compared by ID: registry instances are fixed for the session and the existential is not Equatable.
    let activeApplet: (any MiniApplet)?
    let activeAppletID: String?
    let theme: SuperTheme
    let appearance: ChatAppearance
    let typography: SuperTypography
    let chatState: ChatPresentationState
    let chatProgress: Double
    let chatSemiProgress: Double
    let onBackdropTap: () -> Void
    /// Compared explicitly so a toggle refreshes the onBackdropTap closure's captured value.
    let reduceMotion: Bool

    /// Ignore fresh closure identity; compare its captured Reduce Motion value instead.
    /// Applet ID and theme ID stand in for immutable registry instances and constructed themes.
    /// Keep this view a function of its props; AppShell observes registry changes.
    static func == (lhs: BackdropLayer, rhs: BackdropLayer) -> Bool {
        lhs.activeAppletID == rhs.activeAppletID
            && lhs.theme.id == rhs.theme.id
            && lhs.appearance == rhs.appearance
            && lhs.typography == rhs.typography
            && lhs.chatState == rhs.chatState
            && lhs.chatProgress == rhs.chatProgress
            && lhs.chatSemiProgress == rhs.chatSemiProgress
            && lhs.reduceMotion == rhs.reduceMotion
    }

    /// Piecewise dimming tracks the live geometry-dependent semi anchor. Return to full opacity
    /// behind expanded Chat to avoid an extra transition near the end of an upward drag.
    private var backdropOpacity: Double {
        let p = chatProgress
        let mid = max(0.001, min(0.999, chatSemiProgress))
        if p <= mid {
            let t = p / mid
            return 1.0 + (0.65 - 1.0) * t
        } else {
            let t = (p - mid) / (1 - mid)
            return 0.65 + (1.0 - 0.65) * t
        }
    }

    /// Disable applet hit-testing before expanded Chat fully covers it, preventing stray drag delivery.
    private var backdropHitTestingEnabled: Bool {
        chatProgress < 0.95
    }

    var body: some View {
        // AppletHost excludes drag progress from equality, avoiding an AnyView rebuild every frame.
        AppletHost(
            activeApplet: activeApplet,
            activeAppletID: activeAppletID,
            theme: theme,
            appearance: appearance,
            typography: typography
        )
        .equatable()
        .opacity(backdropOpacity)
        .allowsHitTesting(backdropHitTestingEnabled)
        .overlay {
            if chatState == .semiExpanded {
                // Arm only at the settled semi anchor, not during the whole drag.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onBackdropTap() }
            }
        }
    }
}

/// Excludes chat progress from equality so per-frame dimming never rebuilds the AnyView applet tree.
private struct AppletHost: View, @MainActor Equatable {
    let activeApplet: (any MiniApplet)?
    let activeAppletID: String?
    let theme: SuperTheme
    let appearance: ChatAppearance
    let typography: SuperTypography

    static func == (lhs: AppletHost, rhs: AppletHost) -> Bool {
        lhs.activeAppletID == rhs.activeAppletID
            && lhs.theme.id == rhs.theme.id
            && lhs.appearance == rhs.appearance
            && lhs.typography == rhs.typography
    }

    var body: some View {
        if let activeApplet {
            // Preserve the safe area for applet chrome below the status bar and shell hamburger.
            activeApplet.rootView()
                .superTheme(theme)
                .superFontScale(appearance.fontScale)
                .superTypography(typography)
        }
    }
}

private struct ChatLayer: View {
    let viewModel: ChatScreenViewModel?
    let bootstrapError: String?
    @Binding var chatState: ChatPresentationState
    let composerIsFocused: FocusState<Bool>.Binding
    let theme: SuperTheme
    let appearance: ChatAppearance
    let typography: SuperTypography
    let onManageModels: () -> Void
    let onAddModelRequested: @MainActor @Sendable () -> Void
    let onProgressChange: (Double) -> Void
    let onSemiProgressChange: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Enables cross-fading without requiring the branch view types to be Equatable.
    private var innerDiscriminant: Int {
        if viewModel != nil { 0 }
        else if bootstrapError != nil { 1 }
        else { 2 }
    }

    var body: some View {
        Group {
            if let viewModel {
                ChatOverlay(
                    state: $chatState,
                    viewModel: viewModel,
                    composerIsFocused: composerIsFocused,
                    onManageModels: onManageModels,
                    onAddModelRequested: onAddModelRequested
                )
                .superTheme(theme)
                .chatAppearance(appearance)
                .superTypography(typography)
                .onPreferenceChange(ChatProgressPreferenceKey.self) { newValue in
                    onProgressChange(newValue)
                }
                .onPreferenceChange(ChatSemiProgressPreferenceKey.self) { newValue in
                    onSemiProgressChange(newValue)
                }
                .transition(.opacity)
            } else if let bootstrapError {
                FailureScreen(message: bootstrapError)
                    .transition(.opacity)
            } else {
                // Match the outer launch splash until persisted appearance loads, avoiding a theme flash.
                SplashView()
                    .superTheme(.make(.vellumLight))
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: innerDiscriminant
        )
    }
}

private struct HamburgerLayer: View {
    let theme: SuperTheme
    let chromeVisible: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Clears the button height plus the top safe area.
    private static let hideDistance: CGFloat = 120

    var body: some View {
        VStack {
            HStack {
                FixedHamburgerButton(onTap: onTap)
                    .superTheme(theme)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.top, 4)
        .offset(y: chromeVisible ? 0 : -Self.hideDistance)
        .opacity(chromeVisible ? 1 : 0)
        .animation(SuperMotion.chrome(hiding: !chromeVisible, reduceMotion: reduceMotion), value: chromeVisible)
        // Opacity and offset leave the off-screen button in VoiceOver unless hidden explicitly.
        .accessibilityHidden(!chromeVisible)
    }
}

/// Positions applet accessories outside ChatLayer's immersive offset so they remain
/// visible and move into the hidden pill's slot. ComposerAccessoryFlank owns their chrome.
private struct ComposerAccessoryLayer: View {
    let store: ComposerAccessoryStore
    /// 0 = pill, 1 = expanded; stays at 0 while immersive reading hides the pill.
    let chatProgress: Double
    let composerHidden: Bool
    let theme: SuperTheme
    let typography: SuperTypography
    let reduceMotion: Bool

    /// Matches the composer capsule's side padding.
    private static let sidePadding: CGFloat = 20
    /// Measured above the home indicator; clears the pill and lifts the accessories above it.
    private static let restingInset: CGFloat = ChatPresentationState.minimizedBaseHeight + 36
    /// Matches the hidden composer's resting bottom padding.
    private static let vacatedInset: CGFloat = 16

    private var accessoryOpacity: Double {
        1 - Self.smoothstep(chatProgress, from: 0, to: 0.12)
    }

    var body: some View {
        let buttons = store.buttons
        if !buttons.isEmpty {
            // Measure from the safe-area bottom, matching the composer rather than the screen edge.
            ComposerAccessoryFlank(buttons: buttons)
                .superTheme(theme)
                .superTypography(typography)
                .padding(.horizontal, Self.sidePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, composerHidden ? Self.vacatedInset : Self.restingInset)
                .opacity(accessoryOpacity)
                // Pair hit-testing and accessibility gates during the fade; controls also manage their own visibility.
                .allowsHitTesting(accessoryOpacity > 0.5)
                .accessibilityHidden(accessoryOpacity < 0.5)
                .animation(
                    SuperMotion.chrome(hiding: composerHidden, reduceMotion: reduceMotion),
                    value: composerHidden
                )
        }
    }

    /// Hermite smoothstep — 0 below `lo`, 1 above `hi`, eased between.
    private static func smoothstep(_ x: Double, from lo: Double, to hi: Double) -> Double {
        guard hi > lo else { return x < lo ? 0 : 1 }
        let t = min(1, max(0, (x - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }
}

private struct SidebarLayer: View {
    @Binding var sidebarOpen: Bool
    let sidebarViewModel: SidebarViewModel?
    let appInfo: SuperAppInfo
    let applets: [any MiniApplet]
    let activeAppletID: String?
    let theme: SuperTheme
    let appearance: ChatAppearance
    let typography: SuperTypography
    let onSelectConversation: (String) -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    let onSelectApplet: (String) -> Void
    let onSeeAllChats: () -> Void

    var body: some View {
        if let sidebarViewModel {
            SidebarDrawer(
                isPresented: $sidebarOpen,
                viewModel: sidebarViewModel,
                appInfo: appInfo,
                applets: applets,
                activeAppletID: activeAppletID,
                onSelectConversation: onSelectConversation,
                onNewChat: onNewChat,
                onOpenSettings: onOpenSettings,
                onSelectApplet: onSelectApplet,
                onSeeAllChats: onSeeAllChats
            )
            .superTheme(theme)
            .chatAppearance(appearance)
            .superTypography(typography)
        }
    }
}

/// Defer the database-context factory until the settings model is ready.
private struct SettingsLayer: View {
    @Binding var settingsOpen: Bool
    let settingsViewModel: SettingsViewModel?
    let makeDatabaseContext: () -> DatabaseContext
    let theme: SuperTheme
    let appearance: ChatAppearance
    let typography: SuperTypography

    var body: some View {
        if let settingsViewModel {
            SettingsSheet(
                isPresented: $settingsOpen,
                viewModel: settingsViewModel,
                databaseContext: makeDatabaseContext()
            )
            .superTheme(theme)
            .chatAppearance(appearance)
            .superTypography(typography)
        }
    }
}
