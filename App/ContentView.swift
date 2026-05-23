import Bible
import Chat
import Core
import GRDBQuery
import SwiftUI
import Todo
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
    /// The current settled chat anchor. Starts in `.expanded` so the
    /// app launches into a full-screen chat surface — the backdrop applet
    /// (seeded from persisted state) sits behind, ready to reveal when
    /// the user drags down. Mutates in response to (a) the user dragging
    /// the chat surface and releasing (`ChatOverlay` snaps to the nearest
    /// anchor), (b) tapping the minimized pill, (c) tapping the dimmed
    /// applet backdrop in semi-expanded (→ minimized), (d) selecting an
    /// applet from the sidebar (→ minimized), or (e) selecting an
    /// existing chat / "New Chat" from the sidebar (→ expanded). The
    /// live in-flight drag height lives inside `ChatOverlay`; the
    /// continuously-changing visual progress reaches us via
    /// `chatProgress` below.
    @State private var chatState: ChatPresentationState = .expanded
    /// Live chat-overlay progress (0 = pill, 1 = full screen). Read from
    /// `ChatOverlay`'s `ChatProgressPreferenceKey` so the backdrop applet
    /// can interpolate its opacity and hit-testing alongside the chat's
    /// drag — no more discrete `switch chatState` opacity. Defaults to
    /// `1` so the backdrop stays hidden behind the expanded chat that
    /// renders on first launch before the preference reports anything.
    @State private var chatProgress: Double = 1
    /// Live mid-knot of the backdrop's dim curve — the progress value
    /// at which the chat overlay is settled at semi-expanded. Read from
    /// `ChatOverlay`'s `ChatSemiProgressPreferenceKey` because the semi
    /// anchor's progress is no longer the literal 0.52 ratio; it's
    /// derived from `containerHeight - topInset` and shifts with
    /// device geometry. Defaults to the legacy 0.52 so the first
    /// frame draws a sensible curve before the overlay reports.
    @State private var chatSemiProgress: Double = 0.52
    @State private var viewModel: ChatScreenViewModel?
    /// App-session-lived inbox: subscribes to the `SuperEventBus` and
    /// buffers verse references handed in from Bible until a composer
    /// drains them. Outlives the per-conversation `viewModel`.
    @State private var referenceInbox = ChatReferenceInbox()
    @State private var sidebarViewModel: SidebarViewModel?
    @State private var settingsViewModel: SettingsViewModel?
    @State private var bootstrapError: String?
    @State private var theme: SuperTheme = .make(.light)
    @State private var appearance: ChatAppearance = .default
    @State private var sidebarOpen: Bool = false
    @State private var settingsOpen: Bool = false
    @State private var activeConversationId: String?
    /// Composer focus state, owned by the shell so every "user moved away
    /// from the composer" transition (drag-collapse, hamburger open,
    /// applet switch, conversation pick, backdrop tap) can clear it via
    /// `dismissKeyboard()`. The binding is plumbed into `ChatOverlay →
    /// ChatScreen → ChatComposer` so the same `@FocusState` is the
    /// single source of truth across the whole stack — without that,
    /// the shell could only fire UIKit `resignFirstResponder` (hides
    /// the keyboard visually) while the SwiftUI focus state stayed set
    /// and the keyboard reappeared on the next re-expand.
    @FocusState private var composerIsFocused: Bool
    /// Set the moment `ensureViewModel` enters its critical section so a
    /// re-fired `.task` (scene refresh, identity change) can't race a
    /// second bootstrap before the first finishes. Safe to read/write
    /// without coordination because `.task` runs on the main actor.
    @State private var bootstrapStarted = false
    /// `UserDefaults` key for the persisted backdrop applet ID. The
    /// read at launch lives in `AppBootstrap` now (since the registry is
    /// built there); this key is referenced here for the write-back in
    /// `onSelectApplet`. The two must agree or persistence silently
    /// breaks, so the constant is exposed by `AppBootstrap`.
    private static var activeAppletStorageKey: String { AppBootstrap.activeAppletStorageKey }

    /// Adopts the registry the composition root built. Pre-existing
    /// `applets` array + `UserDefaults` read used to live here; both
    /// moved to `AppBootstrap.bootstrap()` so the same registry is the
    /// source of truth for both the sidebar rail and the briefings
    /// handed to `ChatSessionStore`.
    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _registry = State(initialValue: dependencies.appletRegistry)
    }

    private var appInfo: SuperAppInfo { .fromBundle() }

    /// Honoured by the chat-overlay container's spring and by the
    /// backdrop's opacity transition. Reading it here so the sidebar's
    /// programmatic state flip uses the right animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Each layer below is a separate `View` struct so re-render
        // cost is spread across small focused bodies instead of one
        // monolithic shell body. A composer focus flip still re-runs
        // this body (it owns `@FocusState composerIsFocused`) and each
        // child body (closure-typed inputs like `onBackdropTap` are
        // freshly allocated each render so SwiftUI cannot prove input
        // equality and skip them), but each child body does far less
        // work than the pre-extraction unified body did — no more
        // re-running every `.onChange`/`.task` modifier setup or the
        // entire chrome stack in one pass. Stage 2 (typed-dispatch
        // removal of `MiniApplet.rootView() -> AnyView`) will close
        // the residual cost of the `AnyView` re-wrap inside
        // `BackdropLayer`.
        ZStack {
            BackdropLayer(
                registry: registry,
                theme: theme,
                appearance: appearance,
                chatState: chatState,
                chatProgress: chatProgress,
                chatSemiProgress: chatSemiProgress,
                onBackdropTap: {
                    dismissKeyboard()
                    withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
                        chatState = .minimized
                    }
                }
            )
            ChatLayer(
                viewModel: viewModel,
                bootstrapError: bootstrapError,
                chatState: $chatState,
                composerIsFocused: $composerIsFocused,
                theme: theme,
                appearance: appearance,
                onManageModels: { openSettings(initialPane: .models) },
                onAddModelRequested: { openSettings(initialPane: .modelDetail(id: nil)) },
                onProgressChange: { chatProgress = $0 },
                onSemiProgressChange: { chatSemiProgress = $0 }
            )
            HamburgerLayer(theme: theme, onTap: openSidebar)
            SidebarLayer(
                sidebarOpen: $sidebarOpen,
                sidebarViewModel: sidebarViewModel,
                appInfo: appInfo,
                applets: registry.applets,
                activeAppletID: registry.activeID,
                theme: theme,
                appearance: appearance,
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
                    // Selecting any backdrop applet from the sidebar
                    // collapses the chat to minimized so the user
                    // can interact with the applet. They can drag
                    // the pill up to climb back to semi/expanded.
                    withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
                        chatState = .minimized
                    }
                }
            )
            SettingsLayer(
                settingsOpen: $settingsOpen,
                settingsViewModel: settingsViewModel,
                // Read-only context so SettingsMemoryPane's `@Query`
                // observes the same `chat.sqlite` the LLM writes
                // through MemoryTool. Without it the pane's @Query
                // falls back to its empty defaultValue and the
                // user sees "No memories yet" even when memories
                // exist.
                databaseContext: .readOnly { dependencies.chatDatabase.queue },
                theme: theme,
                appearance: appearance
            )
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
        // Bible's "New chat with this verse" hand-off: start a fresh
        // conversation; the new view model then adopts the verse
        // reference the inbox is still buffering.
        .onChange(of: referenceInbox.wantsNewConversation) { _, wants in
            guard wants, referenceInbox.consumeNewConversationRequest() else { return }
            Task { await startNewChat() }
        }
        // Owner-side keyboard dismissal: every minimize-like transition
        // clears the shell's `@FocusState` *directly*, rather than
        // relying on `ChatScreen`'s in-screen `.onChange(of: progress)`
        // observer (which writes through a cross-module
        // `FocusState<Bool>.Binding` onto a `TextField` that flips
        // `.disabled(true)` in the same render — on iOS 26 that write
        // doesn't reliably propagate, so the keyboard would dismiss
        // visually via the UIKit `resignFirstResponder` dispatch but the
        // focus state stayed `true` and the keyboard re-appeared the
        // moment the field became enabled again on drag-up).
        //
        // `chatState` covers every settled minimize (drag-snap, backdrop
        // tap, applet switch); `chatProgress` covers mid-drag so the
        // keyboard starts tearing down before the snap completes. The
        // shell's `chatProgress` observer fires one preference-propagation
        // tick after `ChatScreen`'s in-screen observer, so the two are
        // not redundant in *time* — `ChatScreen`'s fires first and may
        // silently no-op on iOS 26; this one fires a frame later and
        // lands reliably. Both dismiss calls are idempotent.
        .onChange(of: chatState) { _, newState in
            if newState == .minimized {
                dismissKeyboard()
            }
        }
        .onChange(of: chatProgress) { oldValue, newValue in
            if ChatPresentationState.crossedBelowEditorThreshold(from: oldValue, to: newValue) {
                dismissKeyboard()
            }
        }
        // One bus instance shared by every applet — the Bible backdrop
        // publishes verse references, the Chat overlay's inbox consumes.
        .environment(\.superEventBus, dependencies.eventBus)
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

    /// Dismiss the composer's keyboard before a chrome transition.
    /// Clears the shell-owned ``composerIsFocused`` so SwiftUI doesn't
    /// re-focus the composer on the next render (which would re-show the
    /// keyboard the moment the composer becomes interactive again), and
    /// then dispatches UIKit's `resignFirstResponder` — the load-bearing
    /// piece on iOS 26.x where flipping `@FocusState` alone doesn't
    /// always tear the keyboard down. Both halves are needed: the
    /// `@FocusState` clear is what makes the dismissal durable across a
    /// re-expand; the UIKit dispatch is what reliably hides the keyboard
    /// right now. `#if canImport(UIKit)` compiles the dispatch out on
    /// macOS where there's no on-screen keyboard.
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
            // Begin draining the cross-applet bus before any composer
            // mounts, so a verse added early is buffered, not lost.
            await referenceInbox.attach(to: dependencies.eventBus)
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
            // settings.load() must precede rebuildChatViewModel — provides lastSelectedModelId, verbosity, and theme.
            let settings = SettingsViewModel(
                accountEmail: "brianwang9100@gmail.com",
                appInfo: appInfo,
                settingRepository: dependencies.settingRepository,
                modelRepository: dependencies.modelConfigurationRepository,
                conversationRepository: dependencies.conversationRepository,
                toolRegistry: dependencies.toolRegistry,
                userPersonalizationReceiver: dependencies.chatSessionStore,
                autoCompactPolicyReceiver: dependencies.chatSessionStore,
                // Required for SettingsMemoryPane edit/delete/clear-all
                // to reach the GRDB store. Optional in the type so test
                // fixtures can construct the VM without one — production
                // always wires it.
                memoryRepository: dependencies.memoryRepository,
                llmProviderRegistry: dependencies.llmProviderRegistry,
                httpClient: URLSessionHTTPClient(),
                // Thread the boot-time availability snapshot through so the
                // Settings UI agrees with the seeder/provider hydrator on
                // whether AFM is usable. Re-querying `SystemLanguageModel
                // .default.availability` here would let a mid-session toggle
                // of Apple Intelligence split that answer across surfaces.
                appleFoundationAvailability: dependencies.appleFoundationAvailability
            )
            await settings.load()
            settingsViewModel = settings
            theme = .make(settings.settings.themeId)
            appearance = ChatAppearance(fontScale: settings.settings.fontScale)

            await rebuildChatViewModel(for: conversation)
            await sidebar.refresh()
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
        // Use the persisted model id so the picker survives relaunch; stale ids fall back to first available.
        let persistedModelId = settingsViewModel?.settings.lastSelectedModelId
        let initialModelId = ChatScreenViewModel.resolveInitialModelId(
            persisted: persistedModelId,
            available: providerModels
        )
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
            referenceInbox: referenceInbox
        )
        let registry = dependencies.llmProviderRegistry
        // Fire-and-forget: persisting the pick is best-effort; a dropped write falls back to first-available next launch.
        newModel.onModelSelected = { [weak settings = settingsViewModel] modelId in
            Task {
                await activateProvider(matching: modelId, in: registry)
                await settings?.setLastSelectedModelId(modelId)
            }
        }
        // When the auto-titler lands, repaint the sidebar so the row's
        // "New chat" placeholder flips to the real title without waiting
        // for the next drawer open.
        newModel.onTitleGenerated = { [weak sidebar = sidebarViewModel] _ in
            Task { await sidebar?.refresh() }
        }
        // Mirror the picker's initial pick into the active provider, and persist if it differs from disk.
        if let id = initialModelId {
            await activateProvider(matching: id, in: registry)
            if id != persistedModelId {
                await settingsViewModel?.setLastSelectedModelId(id)
            }
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
        // Picking a different conversation is a context shift — resign
        // the prior composer's focus so the keyboard doesn't slide back
        // up over the newly-loaded transcript on the next render.
        dismissKeyboard()
        // Selecting a chat is an intent to focus on chat — snap the
        // overlay to expanded if the user came from minimized/semi over
        // an applet backdrop.
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
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
        // Starting a fresh chat is a context shift — drop the prior
        // composer's focus so the keyboard doesn't carry into the empty
        // draft when the new view model mounts.
        dismissKeyboard()
        // New Chat is an intent to focus on chat — snap to expanded.
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
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

// MARK: - Shell layers

/// Backdrop layer hosting the active mini-app's root view, plus the
/// semi-expanded tap-target that collapses the chat back to minimized.
///
/// Observes `registry`, `theme`, `appearance`, `chatState`, `chatProgress`,
/// `chatSemiProgress` — *not* `composerIsFocused`. A composer focus flip
/// therefore doesn't re-call `activeApplet.rootView()` here, which is what
/// closes the focus-flip → backdrop-rebuild cascade that prompted the
/// extraction.
private struct BackdropLayer: View {
    let registry: AppletRegistry
    let theme: SuperTheme
    let appearance: ChatAppearance
    let chatState: ChatPresentationState
    let chatProgress: Double
    let chatSemiProgress: Double
    let onBackdropTap: () -> Void

    /// Opacity applied to the applet backdrop, interpolated continuously
    /// against `chatProgress` so the dim tracks the user's drag in
    /// lockstep with the chat surface's height.
    ///
    /// Anchor points (matching the 2026-05-13 design):
    /// - progress 0 (pill): 1.0 — backdrop owns the full screen at full
    ///   opacity.
    /// - progress = `chatSemiProgress` (semi-expanded): 0.65 — backdrop
    ///   is dimmed to read against the floating chat panel. The
    ///   mid-knot is the live semi anchor's resolved progress (now
    ///   geometry-dependent because the semi anchor sits at
    ///   `containerHeight - topInset`), not the legacy 0.52 ratio.
    /// - progress 1 (expanded): 1.0 — backdrop is hidden behind the
    ///   opaque chat anyway, so the value doesn't really matter; we
    ///   leave it at 1 so a flick-up from semi past expanded settles
    ///   without an extra dim transition during the last few percent.
    ///
    /// The curve is piecewise-linear between these three points so the
    /// dim feels coupled to the chat's height rather than snapping at
    /// state boundaries.
    private var backdropOpacity: Double {
        let p = chatProgress
        let mid = max(0.001, min(0.999, chatSemiProgress))
        if p <= mid {
            // 0 → mid: dim from 1.0 down to 0.65 as the chat grows.
            let t = p / mid
            return 1.0 + (0.65 - 1.0) * t
        } else {
            // mid → 1: dim back up to 1.0 (effectively unused — the
            // expanded chat covers the backdrop).
            let t = (p - mid) / (1 - mid)
            return 0.65 + (1.0 - 0.65) * t
        }
    }

    /// Hit-testing on the backdrop turns off the moment the expanded
    /// chat covers (or is about to cover) it, so a drag that lands at
    /// the very top of the screen doesn't end up dispatched to the
    /// applet underneath. Mirrors the pre-change behavior where the
    /// `.expanded` state disabled hit-testing wholesale; here we just
    /// drive it from the live progress so the transition is continuous.
    private var backdropHitTestingEnabled: Bool {
        chatProgress < 0.95
    }

    var body: some View {
        if let activeApplet = registry.activeApplet {
            // The rootView keeps the safe area so each applet can place
            // its own top chrome below the status bar / Dynamic Island
            // and clear the shell's floating hamburger. Applets fill
            // the screen edge-to-edge themselves, extending only their
            // background under the safe area.
            activeApplet.rootView()
                .superTheme(theme)
                .superFontScale(appearance.fontScale)
                .opacity(backdropOpacity)
                .allowsHitTesting(backdropHitTestingEnabled)
                .overlay {
                    if chatState == .semiExpanded {
                        // Transparent tap-target sits above the dimmed
                        // applet only while semi-expanded. An
                        // always-present `.onTapGesture` would consume
                        // applet taps in `.minimized` too, even though
                        // it would no-op there. We attach it to the
                        // settled-state semi anchor so it's gone the
                        // instant the overlay snaps elsewhere — using
                        // `chatProgress` instead would leave the
                        // tap-target armed during the entire drag and
                        // dismiss mid-drag.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { onBackdropTap() }
                    }
                }
        }
    }
}

/// Chat overlay layer. Hosts `ChatOverlay` plus the two
/// `ChatProgressPreferenceKey` observers that surface the live morph
/// progress back to the shell (via the `onProgressChange` /
/// `onSemiProgressChange` closures).
///
/// Owns the binding to the shell's `@FocusState composerIsFocused` —
/// when the composer flips focus, only this layer's body re-evaluates.
private struct ChatLayer: View {
    let viewModel: ChatScreenViewModel?
    let bootstrapError: String?
    @Binding var chatState: ChatPresentationState
    let composerIsFocused: FocusState<Bool>.Binding
    let theme: SuperTheme
    let appearance: ChatAppearance
    let onManageModels: () -> Void
    let onAddModelRequested: @MainActor @Sendable () -> Void
    let onProgressChange: (Double) -> Void
    let onSemiProgressChange: (Double) -> Void

    var body: some View {
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
            .onPreferenceChange(ChatProgressPreferenceKey.self) { newValue in
                onProgressChange(newValue)
            }
            .onPreferenceChange(ChatSemiProgressPreferenceKey.self) { newValue in
                onSemiProgressChange(newValue)
            }
        } else if let bootstrapError {
            FailureScreen(message: bootstrapError)
        } else {
            LoadingScreen()
        }
    }
}

/// Shell-chrome layer: the top-left hamburger. Aligned to topLeading
/// inside the safe area so the status bar doesn't sit on top of it.
private struct HamburgerLayer: View {
    let theme: SuperTheme
    let onTap: () -> Void

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
    }
}

/// Sidebar drawer layer. Body only renders content when
/// `sidebarViewModel` is wired and the drawer is being opened —
/// `SidebarDrawer` itself early-returns on `isPresented == false`.
private struct SidebarLayer: View {
    @Binding var sidebarOpen: Bool
    let sidebarViewModel: SidebarViewModel?
    let appInfo: SuperAppInfo
    let applets: [any MiniApplet]
    let activeAppletID: String?
    let theme: SuperTheme
    let appearance: ChatAppearance
    let onSelectConversation: (String) -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    let onSelectApplet: (String) -> Void

    var body: some View {
        if let sidebarViewModel {
            SidebarDrawer(
                isPresented: $sidebarOpen,
                viewModel: sidebarViewModel,
                appInfo: appInfo,
                userInitials: "BW",
                userName: "Brian Wang",
                applets: applets,
                activeAppletID: activeAppletID,
                onSelectConversation: onSelectConversation,
                onNewChat: onNewChat,
                onOpenSettings: onOpenSettings,
                onSelectApplet: onSelectApplet
            )
            .superTheme(theme)
            .chatAppearance(appearance)
        }
    }
}

/// Settings sheet layer. Body only renders content when
/// `settingsViewModel` is wired; `SettingsSheet` itself early-returns
/// on `isPresented == false`.
private struct SettingsLayer: View {
    @Binding var settingsOpen: Bool
    let settingsViewModel: SettingsViewModel?
    let databaseContext: DatabaseContext
    let theme: SuperTheme
    let appearance: ChatAppearance

    var body: some View {
        if let settingsViewModel {
            SettingsSheet(
                isPresented: $settingsOpen,
                viewModel: settingsViewModel,
                databaseContext: databaseContext
            )
            .superTheme(theme)
            .chatAppearance(appearance)
        }
    }
}

// MARK: - Previews

#Preview("loading") {
    ContentView(state: .loading)
}

#Preview("failed") {
    ContentView(state: .failed("could not open chat.sqlite"))
}
