import Chat
import Core
import GRDBQuery
import os
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Apple-built-in `os.Logger` for shell-level routing diagnostics. Used
/// today for the openRecord deep-link drop case; the subsystem matches
/// the rest of the app so all shell logs filter together in Console.
private let appShellLog = Logger(subsystem: "com.brianwang.Super", category: "app-shell")

/// Hosts the active mini-app's backdrop, the always-on-top chat overlay,
/// the shell-level hamburger chrome, and the sidebar + settings drawers.
///
/// Target-neutral: both `SuperOSApp` and `SuperBibleApp` instantiate the
/// same `AppShell`, handing it an `AppShellDependencies` built from their
/// respective bootstraps. The applet roster the shell shows in the
/// sidebar comes from `dependencies.appletRegistry` — each target's
/// bootstrap pre-fills it with the right mix (SuperOS: Todo + Recipes +
/// Bible + Finance; SuperBible: Bible + Plans-at-SB-M2).
///
/// One backdrop applet is always selected so dragging the chat down
/// reveals a real applet behind it. `init` adopts the registry the
/// bootstrap built; `onSelectApplet` writes the user's pick back to
/// `UserDefaults` via the shared `activeAppletStorageKey` so the
/// selection survives relaunches.
///
/// The shell also owns the sidebar drawer and settings sheet visibility
/// bindings, and the per-conversation view-model rebuild path the chat
/// surface needs when the user picks a different chat from the sidebar.
struct AppShell: View {
    /// `UserDefaults` key for the persisted backdrop applet ID. Hoisted
    /// here (rather than to either bootstrap) because both targets need
    /// the same string and both `SuperOSAppBootstrap` and
    /// `SuperBibleAppBootstrap` read it via this constant. Per-target
    /// `UserDefaults` is sandboxed by bundle id, so the SuperOS and
    /// SuperBible writes don't collide despite sharing the key.
    static let activeAppletStorageKey: String = "shell.activeAppletID"

    let dependencies: AppShellDependencies

    @State private var registry: AppletRegistry
    /// The current settled chat anchor. Seeded from
    /// `dependencies.launchBehavior.initialChatState` in `init` —
    /// `.expanded` for SuperOS (chat fills the screen, backdrop hidden
    /// behind), `.minimized` for SuperBible (Bible visible, chat as a
    /// pill). Mutates in response to (a) the user dragging the chat
    /// surface and releasing (`ChatOverlay` snaps to the nearest anchor),
    /// (b) tapping the minimized pill, (c) tapping the dimmed applet
    /// backdrop in semi-expanded (→ minimized), (d) selecting an applet
    /// from the sidebar (→ minimized), or (e) selecting an existing chat
    /// / "New Chat" from the sidebar (→ expanded). The live in-flight
    /// drag height lives inside `ChatOverlay`; the continuously-changing
    /// visual progress reaches us via `chatProgress` below.
    @State private var chatState: ChatPresentationState
    /// Live chat-overlay progress (0 = pill, 1 = full screen). Read from
    /// `ChatOverlay`'s `ChatProgressPreferenceKey` so the backdrop applet
    /// can interpolate its opacity and hit-testing alongside the chat's
    /// drag — no more discrete `switch chatState` opacity. Seeded in
    /// `init` to match the initial `chatState` (1 for `.expanded`, 0
    /// otherwise) so the backdrop dim is correct on the first frame
    /// before `ChatOverlay`'s preference key reports a value.
    @State private var chatProgress: Double
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
    /// drains them. Outlives the per-conversation `viewModel`. Attached
    /// to the bus from `ensureViewModel`'s `.task` — `attach(to:)` is
    /// idempotent so the call is safe to repeat across identity changes.
    @State private var referenceInbox = ChatReferenceInbox()
    @State private var sidebarViewModel: SidebarViewModel?
    @State private var settingsViewModel: SettingsViewModel?
    @State private var bootstrapError: String?
    @State private var theme: SuperTheme = .make(.light)
    @State private var appearance: ChatAppearance = .default
    /// Active typography (brand serif faces + folded-in font scale).
    /// Rebuilt alongside `theme`/`appearance` from settings at load and on
    /// font-scale / typography-id changes; injected at the same composition
    /// boundaries as `.superTheme`/`.superFontScale`.
    @State private var typography: SuperTypography = .make(SuperTypography.Identifier.serif)
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
    /// Queued navigation request from the cross-applet event bus. The
    /// drain task in `ensureViewModel()` writes here; the body's
    /// `.onChange` reads and dispatches to `selectConversation` /
    /// `startNewChat`. Routing through `@State` (rather than calling
    /// the methods directly from the captured-self drain task) is
    /// load-bearing: a `[self]`-captured closure snapshots `self`
    /// once at task spawn, and `@Environment` values on a struct copy
    /// don't refresh when the OS setting changes — `reduceMotion`
    /// would be frozen at boot time for every routed navigation.
    /// `@State` storage is reference-backed and survives the copy,
    /// and body re-eval gives the dispatcher fresh `@Environment`
    /// values so `withAnimation` honors the live `reduceMotion`.
    @State private var pendingNavigation: PendingNavigation?

    /// Adopts the registry the composition root built. Pre-existing
    /// `applets` array + `UserDefaults` read used to live here; both
    /// moved to each target's bootstrap so the same registry is the
    /// source of truth for both the sidebar rail and the briefings
    /// handed to `ChatSessionStore`.
    ///
    /// `chatState` and `chatProgress` are seeded from
    /// `dependencies.launchBehavior.initialChatState` so the cold-launch
    /// frame matches the per-target policy (SuperOS expanded, SuperBible
    /// pill) without a one-frame flash through the default.
    init(dependencies: AppShellDependencies) {
        self.dependencies = dependencies
        _registry = State(initialValue: dependencies.appletRegistry)
        let initialChatState = dependencies.launchBehavior.initialChatState
        _chatState = State(initialValue: initialChatState)
        // `switch` (not a ternary) so adding a future case to
        // `ChatPresentationState` is a compiler error here rather than a
        // silent fall-through to 0. The `.semiExpanded` arm traps:
        // `AppShellLaunchBehavior` doesn't currently support it as a
        // launch state (the right initial progress depends on container
        // geometry, not a literal), so reaching it means a caller
        // constructed an invalid `AppShellLaunchBehavior` — a debug
        // crash beats a wrong first frame that survives to production.
        // When `.semiExpanded` is ever wired as a launch option, replace
        // this with the named semi-anchor constant from `ChatOverlay`.
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
        // The `referenceInbox` attaches to `SuperEventBus` from
        // `ensureViewModel`'s `.task`. That `.task` fires within a
        // runloop tick of first-render commit — orders of magnitude
        // faster than the human reaction time needed to perceive the
        // Bible reader, recognize a verse, tap it, see the action
        // sheet, and tap "Add to chat". So no `recordAddedToChat`
        // event can fire before the inbox subscribes in practice, and
        // a one-shot init-side `Task` would only introduce ghost
        // subscriptions on every parent re-render of `AppShell`.
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
                typography: typography,
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
                typography: typography,
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
                    // Selecting any backdrop applet from the sidebar
                    // collapses the chat to minimized so the user
                    // can interact with the applet. They can drag
                    // the pill up to climb back to semi/expanded.
                    withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
                        chatState = .minimized
                    }
                },
                onSeeAllChats: {
                    // The Chats applet is the see-all surface for the
                    // sidebar's capped list. Same chrome transition as
                    // any other applet selection — flip the registry,
                    // persist, dismiss keyboard, collapse the chat
                    // overlay so the list owns the screen. No-op when
                    // ChatsApplet isn't registered for this target
                    // (e.g. a hypothetical future target without the
                    // Chats backdrop) — the SidebarDrawer only renders
                    // the See-all row when the underlying list is
                    // capped, which itself only happens once there are
                    // more than 10 conversations.
                    dismissKeyboard()
                    registry.activeID = ChatsApplet.appletID
                    UserDefaults.standard.set(ChatsApplet.appletID, forKey: Self.activeAppletStorageKey)
                    withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
                        chatState = .minimized
                    }
                }
            )
        }
        // Settings presents as a native `.sheet` at the `.large` detent. The
        // drag-down dismiss path only flips `settingsOpen`, so the nav-stack
        // reset that the close button does inline runs here via `onDismiss`.
        .sheet(isPresented: $settingsOpen, onDismiss: { settingsViewModel?.popToRoot() }) {
            SettingsLayer(
                settingsOpen: $settingsOpen,
                settingsViewModel: settingsViewModel,
                // Factory closure: skips the `.readOnly { ... }`
                // allocation during the bootstrap window when
                // `settingsViewModel` is still nil. Once the view
                // model is wired the factory fires per
                // `SettingsLayer.body` re-run — same per-frame churn
                // the pre-extraction inline call had. The context
                // grants `SettingsMemoryPane`'s `@Query` read access
                // to the same `chat.sqlite` the LLM writes through
                // MemoryTool — without it the pane falls back to its
                // empty defaultValue and the user sees "No memories
                // yet" even when memories exist.
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
        // Narrow observers instead of one broad one on `settings`
        // so unrelated mutations (system prompt, verbosity, auto-compact
        // threshold) don't churn the host's render state — only the
        // appearance-relevant fields fire a refresh.
        .onChange(of: settingsViewModel?.settings.themeId) { _, newId in
            if let newId { theme = .make(newId) }
        }
        .onChange(of: settingsViewModel?.settings.fontScale) { _, newScale in
            // A non-nil `newScale` implies the same optional chain's
            // `settingsViewModel` is non-nil, so unwrap it directly rather
            // than threading a dead `?? .serif` fallback through `typographyID`.
            guard let newScale, let settingsViewModel else { return }
            appearance = ChatAppearance(fontScale: newScale)
            typography = .make(settingsViewModel.settings.typographyID, fontScale: newScale)
        }
        .onChange(of: settingsViewModel?.settings.typographyID) { _, newID in
            // Read fontScale from the source of truth (settings), not the
            // derived `appearance` @State — keeps this handler independent of
            // onChange delivery order when both keys change in one update, and
            // mirrors the fontScale handler above.
            guard let newID, let settingsViewModel else { return }
            typography = .make(newID, fontScale: settingsViewModel.settings.fontScale)
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
        // Bible hand-off: a verse (or whole chapter) was published on
        // the bus. Single observable carrying both intents — request
        // shape (`startNew`) and presence — so the two paths can't race
        // and double-animate the chrome. `handleComposerAttention`
        // owns the semi-expand-from-minimized + composer focus.
        .onChange(of: referenceInbox.pendingAttention) { _, _ in
            guard let request = referenceInbox.consumeAttention() else { return }
            Task { await handleComposerAttention(isNewChat: request.startNew) }
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
        // Drain queued navigation requests written by the event-bus
        // task. This observer fires inside a body re-eval, so the
        // `selectConversation` / `startNewChat` calls run on a fresh
        // `self` whose `@Environment` reflects the live OS state
        // (notably `reduceMotion` for `withAnimation`).
        .onChange(of: pendingNavigation) { _, newValue in
            guard let request = newValue else { return }
            pendingNavigation = nil
            Task {
                switch request {
                case .openConversation(let id):
                    await selectConversation(id: id)
                case .newConversation:
                    await startNewChat()
                case .openApplet(let id):
                    selectApplet(id: id)
                }
            }
        }
        // One bus instance shared by every applet — the Bible backdrop
        // publishes verse references, the Chat overlay's inbox consumes.
        .environment(\.superEventBus, dependencies.eventBus)
        // External `super://bible/verse?...` deep links — from Safari,
        // Notes, Messages, Spotlight — feed into the same event-bus
        // path the in-transcript `OpenURLAction` interceptor uses, so
        // every entry point lands the user on the same Bible chapter
        // with the same verses pre-selected. Non-`super://` URLs are
        // ignored here and SwiftUI's default handling continues.
        .onOpenURL { url in
            guard let link = BibleDeepLink(url: url) else { return }
            let eventBus = dependencies.eventBus
            Task { await eventBus.publish(.openRecord(reference: link.recordReference)) }
        }
    }

    /// Switch the active backdrop applet to `id` and collapse the chat
    /// overlay so the applet is on screen. Same chrome transition the
    /// sidebar uses for an explicit pick — keyboard dismissal, registry
    /// mutation, persistence, animated chat-state change — but driven
    /// by an inbound `SuperEvent.openRecord`. No-op when the registry
    /// doesn't host `id` (e.g. a stray deep link for an applet this
    /// build doesn't ship).
    @MainActor
    private func selectApplet(id: String) {
        guard registry.applets.contains(where: { $0.appletID == id }) else {
            // Inbound deep links from outside the app (`super://` URLs in
            // Notes, Spotlight, etc.) can name an applet this build
            // doesn't ship — e.g. a SuperOS-only Todo link opened on a
            // SuperBible device. Drop with a warning so the failure
            // shows up in Console rather than vanishing silently.
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

            // Drain the Chats applet's "open this chat" / "new chat"
            // requests onto the shell's existing routing. The bus
            // does no buffering before subscription, so any event the
            // Chats backdrop publishes after this task starts is
            // delivered exactly once. The task is intentionally
            // long-lived — `AppShell` lives for the whole app session,
            // so cancellation isn't load-bearing.
            //
            // Writes land in `pendingNavigation`, a `@State` whose
            // reference-backed storage survives the struct copy this
            // closure captures. The body's `.onChange` then dispatches
            // from a fresh `self` so `@Environment` reads (notably
            // `reduceMotion`) reflect the live OS setting at the
            // moment of navigation — not the value frozen into this
            // captured copy at task-spawn time.
            let eventBus = dependencies.eventBus
            Task { [self] in
                for await event in await eventBus.events() {
                    switch event {
                    case .openConversationRequested(let id):
                        pendingNavigation = .openConversation(id: id)
                    case .newConversationRequested:
                        pendingNavigation = .newConversation
                    case .recordAddedToChat:
                        // Owned by `ChatReferenceInbox` — skip here so
                        // we don't double-route the verse hand-off.
                        break
                    case .openRecord(let reference):
                        // The receiving applet's own bus subscriber
                        // performs the within-applet navigation; the
                        // shell's job is only to make that applet's
                        // backdrop visible. Route through
                        // `pendingNavigation` so the dispatch runs
                        // inside a body re-eval and `@Environment`
                        // reads (notably `reduceMotion`) are fresh.
                        pendingNavigation = .openApplet(id: reference.appletID)
                    case .bibleAnnotateRequested, .bibleAnnotateCompleted:
                        // Headless Bible → Chat dispatch handshake —
                        // routed end-to-end by
                        // `BibleAnnotateDispatcher` (request) and
                        // `BibleScreenViewModel` (completion). The
                        // shell has no part in the flow and explicitly
                        // skips both envelopes.
                        break
                    }
                }
            }
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
                accountEmail: dependencies.accountEmail,
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
            typography = .make(settings.settings.typographyID, fontScale: settings.settings.fontScale)

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

    /// Open a fresh in-memory draft conversation. `targetChatState`
    /// controls the chrome the chat lands at — sidebar's "New Chat"
    /// passes the default (`.expanded`); the Bible hand-off passes
    /// `.semiExpanded` so the just-attached verse pill is visible
    /// against the applet backdrop behind the floating panel.
    private func startNewChat(targetChatState: ChatPresentationState = .expanded) async {
        sidebarOpen = false
        // Starting a fresh chat is a context shift — drop the prior
        // composer's focus so the keyboard doesn't carry into the empty
        // draft when the new view model mounts. We re-focus the new
        // composer below once the expand animation has visually settled.
        dismissKeyboard()
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
        // Rebuild *before* the animation so the new view model is in
        // place when the overlay slides up — the user never sees a flash
        // of the previous conversation's content during the transition.
        await rebuildChatViewModel(for: row)
        await animateChatState(to: targetChatState)
        composerIsFocused = true
    }

    /// Animate the chat overlay to `target` and return only once the
    /// animation has *logically* settled. The continuation guard is
    /// load-bearing: focus assigned mid-animation collides with iOS
    /// keyboard-avoidance, which reads the composer's in-flight position
    /// and breaks the overlay's spring layout. Logical completion is the
    /// signal that the field has reached its final frame and is safe to
    /// focus.
    ///
    /// Short-circuits when `chatState == target` so a sidebar "New Chat"
    /// tapped while chat is already `.expanded` (the SuperOS cold-launch
    /// default) doesn't pay for a no-op `withAnimation` round-trip plus
    /// a `CheckedContinuation` allocation just to fall through.
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

    /// Cross-applet hand-off has buffered a `RecordReference` for the
    /// composer (today: a Bible verse range or whole chapter via the
    /// action sheet or the spark menu). Owns the visible response:
    /// semi-expand from minimized so the user sees the just-attached
    /// pill, and assign first responder so they can type immediately.
    ///
    /// Sequencing mirrors the sidebar's "New Chat" path
    /// (``startNewChat(targetChatState:)``): animate the chrome, await
    /// logical completion via ``animateChatState(to:)``, *then* focus.
    /// Focusing mid-animation collides with iOS keyboard-avoidance.
    ///
    /// Never demotes from a higher anchor — if the chat is already at
    /// `.semiExpanded` or `.expanded`, leave the chrome alone and only
    /// move focus. The action sheet that fires this path is unreachable
    /// at `.expanded` today (the backdrop is hidden), but the spark menu
    /// could be wired from a future surface, and "snapping down" would
    /// be a regression.
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

// MARK: - Navigation request envelope

/// In-flight navigation written by the cross-applet event-bus drain
/// task and consumed by `AppShell.body`'s `.onChange` observer.
/// Re-entrancy is benign: each enqueue triggers exactly one consume,
/// and the consumer nils out the slot before dispatching so a rapid
/// pair of taps never collapses into one routed call.
private enum PendingNavigation: Equatable {
    case openConversation(id: String)
    case newConversation
    /// Switch the active backdrop applet to the given id and collapse
    /// the chat overlay so the applet is on screen. Driven by inbound
    /// `SuperEvent.openRecord(reference:)` — e.g. a Bible-citation tap
    /// in the Chat transcript or a `super://bible/...` deep link.
    case openApplet(id: String)
}

// MARK: - Shell layers

/// Backdrop layer hosting the active mini-app's root view, plus the
/// semi-expanded tap-target that collapses the chat back to minimized.
///
/// Observes `registry`, `theme`, `appearance`, `chatState`, `chatProgress`,
/// `chatSemiProgress`. Closure-typed inputs (`onBackdropTap`) are
/// freshly allocated each `AppShell.body` render, so SwiftUI cannot prove
/// input equality and *will* re-run this body on a composer focus flip
/// — but it's a small body, far cheaper than the pre-extraction unified
/// shell body. Stage 2 (typed-dispatch removal of
/// `MiniApplet.rootView() -> AnyView`) will close the residual
/// `activeApplet.rootView()` re-wrap cost that remains here.
private struct BackdropLayer: View {
    let registry: AppletRegistry
    let theme: SuperTheme
    let appearance: ChatAppearance
    let typography: SuperTypography
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
                .superTypography(typography)
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
/// Owns the binding to the shell's `@FocusState composerIsFocused`
/// — this is the layer that genuinely needs to re-render on focus
/// flip (the `TextField` itself lives further down in `ChatOverlay
/// → ChatScreen → ChatComposer`). The other layers also re-render
/// on each `AppShell.body` re-eval because their closure inputs
/// aren't equatable, but their bodies are small.
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

    /// Discriminant for the chat-overlay vs error vs splash fallback so
    /// `.animation(value:)` can cross-fade the inner swap without forcing
    /// either branch's value type to be `Equatable`.
    private var innerDiscriminant: Int {
        if viewModel != nil { 0 }
        else if bootstrapError != nil { 1 }
        else { 2 }
    }

    var body: some View {
        // Per-branch .transition + outer .animation = real cross-fade.
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
                // Pin Light: matches the outer per-target content view splash before
                // user settings load, so the fallback during the brief
                // pre-ensureViewModel window doesn't flash a wrong theme.
                SplashView()
                    .superTheme(.make(.light))
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: innerDiscriminant
        )
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

/// Sidebar drawer layer. Renders `SidebarDrawer` whenever
/// `sidebarViewModel` is non-nil; `SidebarDrawer` itself handles
/// the `isPresented == false` case internally.
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

/// Settings sheet layer. Body only renders content when
/// `settingsViewModel` is wired; `SettingsSheet` itself early-returns
/// on `isPresented == false`.
///
/// `makeDatabaseContext` is a factory closure (not a stored value) so
/// the `.readOnly { ... }` allocation is skipped during the bootstrap
/// window where `settingsViewModel` is still nil. Once the view model
/// is wired, this body re-runs on each `AppShell.body` re-eval (closure
/// inputs aren't equatable, so SwiftUI can't skip it) and a fresh
/// `DatabaseContext` is constructed per render — same per-frame churn
/// the pre-extraction inline `SettingsSheet(...)` call already had, so
/// no behavior regression vs. before the extraction.
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
