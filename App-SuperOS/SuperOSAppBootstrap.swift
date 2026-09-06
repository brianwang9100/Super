import Bible
import Chat
import Core
import Foundation
import FoundationModels
import SwiftUI
import Todo

/// Wired-up dependency graph the Shell hands to its views.
///
/// Constructed exactly once on app launch by `SuperOSAppBootstrap.bootstrap()`. The
/// Shell stores it in app state and injects the pieces individual views need
/// via `@Environment` (UI wiring lands in M7).
@MainActor
struct SuperOSAppDependencies {
    let chatDatabase: ChatDatabase
    let chatSessionStore: ChatSessionStore
    let toolRegistry: ToolRegistry
    let llmProviderRegistry: LLMProviderRegistry
    let conversationRepository: any ConversationRepository
    let messageRepository: any MessageRepository
    let toolCallRepository: any ToolCallRepository
    let checkpointRepository: any CompactionCheckpointRepository
    let modelConfigurationRepository: any ModelConfigurationRepository
    let settingRepository: any SettingRepository
    let memoryRepository: any MemoryRepository
    /// Sorted ids of tools registered at boot. Surfaced so the Shell can
    /// show "Tools: time.now" until the real Settings UI lands.
    let registeredToolIDs: [String]
    /// The Todo applet's own database + repositories, bundled so the Shell
    /// can hand them to `TodoApplet`.
    let todoDependencies: TodoDependencies
    /// App-wide cross-applet event bus. The Shell injects it into every
    /// applet's environment so Bible can hand verse references to Chat.
    let eventBus: SuperEventBus
    /// Composition-root-built registry of every `MiniApplet` installed in
    /// this build. Owned here (rather than rebuilt by `AppShell.init`) so
    /// the same registry is the source of truth for both the sidebar
    /// rail's backdrop list and the briefings handed to
    /// `ChatSessionStore` — keeping the two in lock-step.
    let appletRegistry: AppletRegistry
    /// AFM availability snapshot taken at boot. Threaded forward so view
    /// models built later in the session (`SettingsViewModel`,
    /// `ChatScreenViewModel`) read the same value the seeder/provider
    /// hydrator already used — re-querying `SystemLanguageModel.default
    /// .availability` could otherwise return a different state mid-session
    /// (e.g. user just toggled Apple Intelligence in Settings) and split
    /// the UI's "is AFM usable" answer across surfaces.
    let appleFoundationAvailability: AppleFoundationAvailability
    let appleFoundationStatusProvider: any AppleFoundationModelStatusProvider
    /// Headless `bible.annotate` dispatcher. Held here so it lives as
    /// long as the dependency graph does — its bus subscription is
    /// owned by the instance, so dropping the reference would silently
    /// kill the headless dispatch path.
    let bibleAnnotateDispatcher: BibleAnnotateDispatcher
    /// Shared app-wide haptics engine. One instance threaded into both the
    /// shell (via `shellDependencies`) and the applets registered here, so
    /// the Settings toggle mutes every surface at once.
    let hapticsEngine: any HapticsEngine

    /// Slice of this dependency graph that `AppShell` actually reads.
    /// Built on demand so callers don't have to thread every field
    /// individually; the shell lives in `App/Shell/` and is shared with
    /// SuperBible, so it can't depend on the SuperOS-only `SuperOSAppDependencies`
    /// type directly. The matching `SuperBibleAppDependencies` exposes
    /// the same property.
    var shellDependencies: AppShellDependencies {
        AppShellDependencies(
            chatDatabase: chatDatabase,
            chatSessionStore: chatSessionStore,
            toolRegistry: toolRegistry,
            llmProviderRegistry: llmProviderRegistry,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            toolCallRepository: toolCallRepository,
            checkpointRepository: checkpointRepository,
            modelConfigurationRepository: modelConfigurationRepository,
            settingRepository: settingRepository,
            memoryRepository: memoryRepository,
            eventBus: eventBus,
            appletRegistry: appletRegistry,
            appleFoundationAvailability: appleFoundationAvailability,
            appleFoundationStatusProvider: appleFoundationStatusProvider,
            hapticsEngine: hapticsEngine,
            // SuperOS keeps the standard launch policy: chat opens
            // expanded over the user's last-used applet (restored by
            // `UserDefaults` lookup further down in `bootstrap()`).
            launchBehavior: .standard,
            // SuperOS doesn't use the composer's hovering flank buttons —
            // the Bible reader's chapter chevrons stay in its nav bar here.
            composerAccessoryStore: nil
        )
    }
}

/// One-shot composition root. Bootstraps the on-disk database, every
/// repository, the tool/provider registries, and the `ChatSessionStore`.
///
/// Lives in `App-SuperOS/` (not in any package) because it pulls together
/// pieces from both Core and Chat — i.e. it is the place those modules
/// first meet. Symmetric with `App-SuperBible/SuperBibleAppBootstrap.swift`;
/// the shared shell lives at `App/Shell/`.
enum SuperOSAppBootstrap {
    /// Build the full dependency graph.
    ///
    /// - Parameters:
    ///   - directory: Where `chat.sqlite` lives. Defaults to the user's
    ///     Application Support directory under `Super/`. Tests pass a temp
    ///     directory.
    ///   - keychain: Keychain backend. Defaults to `AppleKeychainClient`;
    ///     tests inject `InMemoryKeychainClient` so the suite doesn't touch
    ///     the user's real Keychain.
    /// - Throws: Any GRDB or filesystem error from opening the database, or
    ///   any Keychain error encountered while hydrating saved providers.
    @MainActor
    static func bootstrap(
        directory: URL? = nil,
        keychain: (any KeychainClient)? = nil
    ) async throws -> SuperOSAppDependencies {
        let dataDirectory = try directory ?? AppBootstrapSupport.defaultDataDirectory()
        try AppBootstrapSupport.ensureDirectoryExists(dataDirectory)

        let database = try ChatDatabase.open(in: dataDirectory)
        let keychain = keychain ?? AppleKeychainClient()

        // The Todo applet owns its own `todo.sqlite` alongside `chat.sqlite`.
        let todoDependencies = try TodoDependencies.live(in: dataDirectory)

        let conversationRepo = GRDBConversationRepository(database: database)
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let modelConfigRepo = GRDBModelConfigurationRepository(database: database, keychain: keychain)
        let settingRepo = GRDBSettingRepository(database: database)
        let toolEnablementRepository = GRDBToolEnablementRepository(database: database)
        let memoryRepository = GRDBMemoryRepository(database: database)

        let toolRegistry = ToolRegistry(enablementRepository: toolEnablementRepository)
        await toolRegistry.register(TimeNowTool.registration())
        await toolRegistry.register(MemoryTool.registration(repository: memoryRepository))

        // Construct Bible up-front for two downstream wirings:
        //   1. `registerAnnotationTool(in:)` here so `bible.annotate` is
        //      registered against the shared `ToolRegistry`. The applet
        //      owns `bible.sqlite` (opened inside `BibleApplet.init`), so
        //      tool registration funnels through this helper rather than
        //      the bootstrap building the repository directly. No-op when
        //      the database failed to open.
        //   2. `attach(to:)` below, once the shared `SuperEventBus` exists,
        //      so the applet's `BibleReferenceInbox` receives Chat-side
        //      verse-citation taps. Struct copies share the same inbox
        //      reference (it's a class), so attaching the locally-held
        //      value before the struct is moved into `AppletRegistry` is
        //      sufficient for every copy.
        // Constructed here (rather than after the AFM seed below) so the
        // annotation tool can be registered with a model-aware stamp
        // provider that captures it. `hydrateProviders` still runs later;
        // the stamp provider reads the active model lazily at
        // tool-execution time, long after hydration.
        let llmProviderRegistry = LLMProviderRegistry()

        // One haptics engine for the whole app — shared by the shell's
        // environment, the chat + Settings view models, and the applets
        // registered below.
        let hapticsEngine = SystemHapticsEngine()

        let bibleApplet = BibleApplet(hapticsEngine: hapticsEngine)
        await bibleApplet.registerAnnotationTool(
            in: toolRegistry,
            stampProvider: ActiveModelBibleAnnotationStampProvider(registry: llmProviderRegistry)
        )
        await bibleApplet.registerNoteTool(in: toolRegistry)
        await bibleApplet.registerHighlightTool(in: toolRegistry)
        await bibleApplet.registerLookupTool(in: toolRegistry)

        // Constructed here (rather than inline in the `applets` array below)
        // so it can register the `todo.create` tool with the shared registry;
        // the local is reused for the registry slot below. Mirrors how
        // `bibleApplet` registers its tools.
        let todoApplet = TodoApplet(dependencies: todoDependencies)
        await todoApplet.registerCreateTool(in: toolRegistry)

        // Persist the OS-appropriate default independently of temporary
        // readiness. Populated stores (including OS upgrades) are untouched.
        let appleStatusProvider = LiveAppleFoundationModelStatusProvider()
        let bootAvailability = AppleFoundationAvailability(
            SystemLanguageModel.default.availability
        )
        try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: modelConfigRepo,
            model: appleStatusProvider.supportsPrivateCloudCompute ? .privateCloudCompute : .local
        )

        #if DEBUG
        // Swallow seed failures: a transient GRDB error here (WAL
        // contention, full disk) should *not* crash bootstrap on a
        // simulator — the debug provider just doesn't show up in the
        // picker until the next launch. Mirrors the do/catch the
        // production AFM seed above uses, but with `print` instead of
        // `assertionFailure` so dev-loop annoyance is bounded to a log
        // line rather than a hard trap.
        do {
            // Gate the "Debug (todo)" row on the Todo applet being injected —
            // its tool is registered above, so the registry is the source of
            // truth for "is Todo present in this build".
            let includesTodoTool = await toolRegistry.registration(toolID: TodoCreateTool.toolID) != nil
            try await AppBootstrapSupport.seedDebugModelIfNeeded(
                repository: modelConfigRepo,
                includesTodoTool: includesTodoTool
            )
        } catch {
            print("[DebugLLMProvider] seed failed: \(error)")
        }
        #endif
        try await AppBootstrapSupport.hydrateProviders(
            into: llmProviderRegistry,
            from: modelConfigRepo,
            toolRegistry: toolRegistry,
            appleFoundationAvailability: bootAvailability,
            appleFoundationStatusProvider: appleStatusProvider
        )

        let compactor = Compactor(
            llmProviderRegistry: llmProviderRegistry,
            checkpointRepository: checkpointRepo
        )

        // Pre-load Chat settings so the session store starts with the
        // user's persisted auto-compact policy and personalization — newly
        // created sessions would otherwise pick up the orchestration-layer
        // fallbacks until the user re-saved each value from Settings.
        //
        // The transient `ChatSettingsStore` is safe to discard: the type
        // is documented as a stateless wrapper over `SettingRepository`
        // (see `ChatSettingsStore.swift:6-9`). `SettingsViewModel` builds
        // its own instance from the same repo for live mutations, and
        // the two cannot diverge because there is no cached state to
        // share. If `ChatSettingsStore` ever gains caching or
        // observation, lift this to a single shared instance passed to
        // both `ChatSessionStore` (seed) and `SettingsViewModel` (live).
        let initialSettings = await ChatSettingsStore(repository: settingRepo).load()

        // Build the applet list here (rather than in `AppShell.init`) so
        // the same applets feed both the sidebar rail and the leading
        // system block sent to the Large Language Model (LLM) on every
        // chat turn — those two surfaces would otherwise drift if a
        // future PR registered an applet in only one place.
        // (`bibleApplet` is constructed earlier so it can register the
        // `bible.annotate` tool with the shared registry; the local is
        // reused here for the registry slot and again below for
        // `attach(to: eventBus)`.)
        let applets: [any MiniApplet] = [
            // Order is the sidebar rail order: `ChatsApplet` sits first
            // so Chats is the most prominent entry. Note this is now
            // decoupled from the cold-start default — that default is
            // pinned explicitly to Todo via the `resolvedID` fallback
            // below, *not* taken from this array's first element. Don't
            // re-couple them: reordering this array must not change the
            // fresh-install landing surface.
            ChatsApplet(chatDatabase: database),
            todoApplet,
            RecipesPlaceholderApplet(),
            bibleApplet,
            FinancePlaceholderApplet(),
        ]
        // Resolve the persisted active backdrop here (was in
        // `AppShell.init`). Fallback chain keeps the invariant that
        // some backdrop is always selected: persisted id if it still
        // matches a registered applet, else Todo as the cold-start
        // default. The fallback is pinned to `TodoApplet.appletID`
        // (not `applets.first`) so the sidebar order above can change
        // without moving the fresh-install landing surface — mirrors
        // SuperBible's explicit `initialActiveID:` approach.
        let resolvedID = AppletRegistry.resolveActiveID(
            applets: applets,
            storedID: UserDefaults.standard.string(forKey: AppShell.activeAppletStorageKey),
            fallbackID: TodoApplet.appletID
        )
        let appletRegistry = AppletRegistry(
            applets: applets,
            initialActiveID: resolvedID
        )

        // Per-applet briefings — already trimmed and sorted by
        // `appletID`. Empty bodies are skipped at the registry level so
        // placeholder applets don't contribute stray `## <Name> applet`
        // headers to the leading system block.
        let appletBriefings = appletRegistry.resolvedBriefings()
        // The Chat-assistant base prompt is the `DefaultSystemPrompt.md`
        // resource shipped inside the Chat package. `ChatBriefing.load()`
        // calls `AppletSystemPrompt.load(from: .module, ...)` from
        // within the Chat package so `.module` resolves to Chat's
        // bundle — calling it directly from `App/` would resolve to
        // the App target's bundle, which doesn't ship the markdown.
        // The `.compact` variant is the lean persona small-window models
        // (on-device Apple Foundation Model) receive instead.
        let chatBriefing = ChatBriefing.load()
        let compactChatBriefing = ChatBriefing.loadCompact()

        // DEBUG-only: mock-search backend fulfiller so the seeded "Debug
        // (mock search)" model exercises the full search flow with no key.
        #if DEBUG
        let webSearchFulfiller: (any WebSearchFulfilling)? = DebugWebSearchFulfiller()
        #else
        let webSearchFulfiller: (any WebSearchFulfilling)? = nil
        #endif

        let chatSessionStore = ChatSessionStore(
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmProviderRegistry,
            toolRegistry: toolRegistry,
            compactor: compactor,
            autoCompactEnabled: initialSettings.autoCompactEnabled,
            autoCompactThreshold: initialSettings.autoCompactThreshold,
            askBeforeSearching: initialSettings.askBeforeSearching,
            chatBriefing: chatBriefing,
            compactChatBriefing: compactChatBriefing,
            appletBriefings: appletBriefings,
            // Live active-applet accessor: on the compact tier the session
            // injects only the active applet's briefing — with SuperOS's
            // multi-applet registry this is most of the briefing savings.
            activeAppletID: { await appletRegistry.activeID },
            userPersonalization: initialSettings.userPersonalization,
            memoryRepository: memoryRepository,
            webSearchFulfiller: webSearchFulfiller
        )

        // Resolve tool calls stranded by a prior crash/force-quit before any
        // session can stream — a stranded `tool_use` without its result row
        // otherwise replays as provider-invalid history on the next turn.
        await chatSessionStore.recoverInterruptedToolCalls()

        let registeredToolIDs = await toolRegistry.allRegistrations().map(\.tool.id)

        // Single shared event bus — created here (not inline in the
        // return) so we can subscribe `BibleApplet` to inbound deep
        // links from the Chat-side citation linkifier and the scene
        // root's `.onOpenURL` handler before handing the bus to the
        // shell.
        let eventBus = SuperEventBus()
        await bibleApplet.attach(to: eventBus)

        // Bible → Chat headless dispatch (PR4): a fresh
        // single-tool `ToolRegistry` exposing only `bible.annotate`
        // so the transient session can't reach for any other tool.
        // Mirrors the SuperBible bootstrap's identical wiring.
        let bibleAnnotateRegistry = ToolRegistry()
        await bibleApplet.registerAnnotationTool(
            in: bibleAnnotateRegistry,
            stampProvider: ActiveModelBibleAnnotationStampProvider(registry: llmProviderRegistry)
        )
        let bibleAnnotateDispatcher = BibleAnnotateDispatcher(
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmProviderRegistry,
            toolRegistry: bibleAnnotateRegistry,
            compactor: compactor
        )
        await bibleAnnotateDispatcher.attach(to: eventBus)

        return SuperOSAppDependencies(
            chatDatabase: database,
            chatSessionStore: chatSessionStore,
            toolRegistry: toolRegistry,
            llmProviderRegistry: llmProviderRegistry,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            modelConfigurationRepository: modelConfigRepo,
            settingRepository: settingRepo,
            memoryRepository: memoryRepository,
            registeredToolIDs: registeredToolIDs,
            todoDependencies: todoDependencies,
            eventBus: eventBus,
            appletRegistry: appletRegistry,
            appleFoundationAvailability: bootAvailability,
            appleFoundationStatusProvider: appleStatusProvider,
            bibleAnnotateDispatcher: bibleAnnotateDispatcher,
            hapticsEngine: hapticsEngine
        )
    }

}
