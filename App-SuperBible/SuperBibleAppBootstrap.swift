import Bible
import Chat
import Core
import Foundation
import FoundationModels
import SwiftUI

/// Wired-up dependency graph the SuperBible shell hands to its views.
///
/// Mirrors `SuperOSAppDependencies` field-for-field on the
/// Chat-infra side and exposes the same `shellDependencies` slicer so
/// the shared `AppShell` consumes both targets uniformly. The Todo /
/// placeholder-applet fields are omitted because SuperBible's v1 applet
/// set is Chat (host) + Bible + Plans (at SB-M2).
@MainActor
struct SuperBibleAppDependencies {
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
    let eventBus: SuperEventBus
    let appletRegistry: AppletRegistry
    let appleFoundationAvailability: AppleFoundationAvailability
    let appleFoundationStatusProvider: any AppleFoundationModelStatusProvider
    /// Headless `bible.annotate` dispatcher. Held here so it lives as
    /// long as the dependency graph does — its bus subscription is
    /// owned by the instance, so dropping the reference would silently
    /// kill the headless dispatch path.
    let bibleAnnotateDispatcher: BibleAnnotateDispatcher

    /// Applet-contributed Settings surfaces (Bible's "Annotations" hub),
    /// injected into the shell's environment by `SuperBibleContentView` so the
    /// Chat-hosted Settings can render them without importing Bible.
    let appletSettingsContributions: [AppletSettingsContribution]

    /// Drives an active bulk-annotation run on a `BGProcessingTask` while the app
    /// is backgrounded. Held by the app's `BulkAnnotationBackgroundController` so
    /// it survives the Settings screen being dismissed. `nil` when the Bible
    /// database failed to open (bulk generation is then unavailable anyway).
    let bulkAnnotationBackground: BulkAnnotationBackgroundScheduler?

    /// Shared holder for the chat composer's hovering flank buttons. The Bible
    /// reader publishes its previous / next chapter chevrons here so they render
    /// above the minimized composer pill; the shell injects it into the backdrop
    /// subtree (writer) and the composer-accessory layer (reader). SuperBible-only.
    let composerAccessoryStore: ComposerAccessoryStore

    /// Shared app-wide haptics engine. One instance threaded into both the
    /// shell (via `shellDependencies`) and the applets registered here.
    let hapticsEngine: any HapticsEngine

    /// Slice handed to `AppShell`. Matches `SuperOSAppDependencies.shellDependencies`
    /// so the same shell renders both targets — the only difference visible
    /// to the shell is the applet set inside `appletRegistry`.
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
            // SuperBible diverges from SuperOS: every cold launch opens to
            // Bible with the chat overlay as a pill. The applet override
            // is enforced separately in `bootstrap()` (UserDefaults skip
            // + `applets.first?.appletID`); this knob covers the chat
            // anchor only. See App-SuperBible/AGENTS.md § Launch behavior.
            launchBehavior: AppShellLaunchBehavior(initialChatState: .minimized),
            // SuperBible hovers the Bible reader's chapter chevrons above the
            // composer pill; the same store the Bible backdrop writes to.
            composerAccessoryStore: composerAccessoryStore
        )
    }
}

/// One-shot composition root for the SuperBible target. Stays separate
/// from `SuperOSAppBootstrap` because the two apps register different
/// applet sets — but the generic plumbing (directory creation, provider
/// hydration, debug-model seed) is shared through `AppBootstrapSupport`.
///
/// Lives in `App-SuperBible/` for symmetry with
/// `App/SuperOSAppBootstrap.swift`. Both files compile in their owner
/// target only; `App/Shell/` content (`AppShell`, `AppShellDependencies`,
/// `AppBootstrapSupport`) is what crosses into the SuperBible target via
/// the explicit `sources:` entries in `project.yml`.
enum SuperBibleAppBootstrap {
    /// Build the full dependency graph.
    ///
    /// - Parameters:
    ///   - directory: Where `chat.sqlite` and `bible.sqlite` live.
    ///     Defaults to the user's Application Support directory under
    ///     `Super/` (inside SuperBible's own per-bundle-id container).
    ///     Tests pass a temp directory.
    ///   - keychain: Keychain backend. Defaults to `AppleKeychainClient`;
    ///     tests inject `InMemoryKeychainClient` so the suite doesn't
    ///     touch the user's real Keychain.
    /// - Throws: Any GRDB or filesystem error from opening the database,
    ///   or any Keychain error encountered while hydrating saved providers.
    @MainActor
    static func bootstrap(
        directory: URL? = nil,
        keychain: (any KeychainClient)? = nil
    ) async throws -> SuperBibleAppDependencies {
        let dataDirectory = try directory ?? AppBootstrapSupport.defaultDataDirectory()
        try AppBootstrapSupport.ensureDirectoryExists(dataDirectory)

        let database = try ChatDatabase.open(in: dataDirectory)
        let keychain = keychain ?? AppleKeychainClient()

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
        //      verse-citation taps.
        // Constructed here (rather than after the AFM seed below) so the
        // annotation tool can be registered with a model-aware stamp
        // provider that captures it. `hydrateProviders` still runs later;
        // the stamp provider reads the active model lazily at
        // tool-execution time, long after hydration.
        let llmProviderRegistry = LLMProviderRegistry()

        // One haptics engine for the whole app — shared by the shell's
        // environment, the chat + Settings view models, and the Bible applet.
        let hapticsEngine = SystemHapticsEngine()

        let bibleApplet = BibleApplet(hapticsEngine: hapticsEngine)
        await bibleApplet.registerAnnotationTool(
            in: toolRegistry,
            stampProvider: ActiveModelBibleAnnotationStampProvider(registry: llmProviderRegistry)
        )
        await bibleApplet.registerNoteTool(in: toolRegistry)
        await bibleApplet.registerHighlightTool(in: toolRegistry)
        await bibleApplet.registerLookupTool(in: toolRegistry)

        // Bible's "Annotations" hub for the shared Settings screen is built
        // further down, once the `.userBulk` annotate dispatcher it drives
        // exists (it needs `compactor` + the repos constructed below).

        // Match SuperOS: OS support chooses the persisted default, never
        // a transient readiness/network result. Existing stores are untouched.
        let appleStatusProvider = LiveAppleFoundationModelStatusProvider()
        let bootAvailability = AppleFoundationAvailability(
            SystemLanguageModel.default.availability
        )
        try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: modelConfigRepo,
            model: appleStatusProvider.supportsPrivateCloudCompute ? .privateCloudCompute : .local
        )

        #if DEBUG
        do {
            try await AppBootstrapSupport.seedDebugModelIfNeeded(repository: modelConfigRepo)
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

        let initialSettings = await ChatSettingsStore(repository: settingRepo).load()

        // SuperBible v1 applet set: Chats (searchable history list,
        // distinct from the chat overlay) + Bible + Bookmarks (the Bible
        // companion list of chapter bookmarks). Plans joins at SB-M2;
        // no Todo or productivity-style placeholders ever (per
        // `App-SuperBible/AGENTS.md` § Module identity). The array order
        // drives the sidebar rail order — Chats first so the rail leads
        // with the user's chats. The cold-launch active backdrop is
        // decoupled from this order: `initialActiveID` is set explicitly
        // to `BibleApplet.appletID` below. (`bibleApplet` is constructed
        // earlier so it can register the `bible.annotate` tool with the
        // shared registry; the local is reused here for the registry slot
        // and again below for `attach(to: eventBus)`.)
        let applets: [any MiniApplet] = [
            ChatsApplet(chatDatabase: database),
            bibleApplet,
            // Bookmarks shares Bible's `bible.sqlite` via a handed-over
            // read-only `DatabaseContext` (the Bible-internal `BibleDatabase`
            // never leaks to the root). SuperBible-only: SuperOS deliberately
            // does not register it.
            bibleApplet.makeBookmarksApplet(),
        ]
        // SuperBible diverges from SuperOS: the persisted active applet
        // in `UserDefaults` is *deliberately ignored* on cold launch.
        // Every app open lands on Bible regardless of where the user
        // navigated mid-session in the prior run. Pair with
        // `launchBehavior: AppShellLaunchBehavior(initialChatState:
        // .minimized)` in `shellDependencies` so the chat overlay also
        // opens as a pill. `BibleApplet.appletID` is passed explicitly
        // (rather than `applets.first?.appletID`) so the sidebar rail
        // order can change independently of the cold-launch backdrop.
        // The shell still *writes* to `activeAppletStorageKey` when the
        // user picks an applet — that write is harmless dead weight
        // here. See App-SuperBible/AGENTS.md § Launch behavior.
        let appletRegistry = AppletRegistry(
            applets: applets,
            initialActiveID: BibleApplet.appletID
        )

        // Per-applet briefings via the same `resolvedBriefings()` helper
        // SuperOS uses — sorted by `appletID`, empty bodies skipped.
        let appletBriefings = appletRegistry.resolvedBriefings()
        // The SuperBible-flavor Chat-assistant base prompt. Reads
        // `Resources/SuperBibleSystemPrompt.md` from the App-SuperBible
        // target bundle (i.e., `Bundle.main`), not Chat's SwiftPM
        // bundle — `ChatBriefing.load()` (used by SuperOS) would
        // otherwise return Chat's generic `DefaultSystemPrompt.md`.
        // The `.compact` variant is the lean persona small-window models
        // (on-device Apple Foundation Model) receive instead.
        let chatBriefing = SuperBibleSystemPromptLoader.load()
        let compactChatBriefing = SuperBibleSystemPromptLoader.loadCompact()

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
            // injects only the active applet's briefing.
            activeAppletID: { await appletRegistry.activeID },
            userPersonalization: initialSettings.userPersonalization,
            memoryRepository: memoryRepository,
            webSearchFulfiller: webSearchFulfiller
        )

        // Resolve tool calls stranded by a prior crash/force-quit before any
        // session can stream — a stranded `tool_use` without its result row
        // otherwise replays as provider-invalid history on the next turn.
        await chatSessionStore.recoverInterruptedToolCalls()

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
        // The shared user-facing registry stays unchanged. The
        // dispatcher subscribes to `bibleAnnotateRequested` on the
        // same bus the Bible UI publishes on.
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

        // Bible → bulk-annotation generation: a SECOND single-tool dispatcher,
        // stamped `.userBulk` (vs the spark button's `.user`), driven directly
        // by the Bible-side `BulkAnnotationRunner` rather than the event bus —
        // so it is deliberately NOT `attach`-ed. Injected as the runner's
        // `BibleAnnotateGenerating` seam at the Annotations Settings hub.
        let bibleBulkAnnotateRegistry = ToolRegistry()
        await bibleApplet.registerAnnotationTool(
            in: bibleBulkAnnotateRegistry,
            stampProvider: ActiveModelBibleAnnotationStampProvider(
                registry: llmProviderRegistry,
                source: .userBulk
            )
        )
        let bibleBulkAnnotateDispatcher = BibleAnnotateDispatcher(
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmProviderRegistry,
            toolRegistry: bibleBulkAnnotateRegistry,
            compactor: compactor
        )

        // The Annotations hub + background scheduler, both backed by one shared
        // runner. Cost confirmation stays enabled; PCC also consumes quota,
        // so the OS-specific default must not bypass confirmation. The
        // background scheduler is handed to the app's lifecycle
        // controller so a run keeps draining on a BGProcessingTask while the app
        // is suspended.
        let bulkWiring = bibleApplet.makeBulkAnnotationWiring(
            requiresCostConfirmation: true,
            generator: bibleBulkAnnotateDispatcher,
            currentModelID: { await llmProviderRegistry.activeID() ?? "" }
        )
        let bibleSettingsContributions = bulkWiring.map { [$0.settingsContribution] } ?? []

        // Shared composer-flank holder: the Bible reader writes its prev / next
        // chapter chevrons here and the shell renders them above the composer
        // pill. Created once for the app session.
        let composerAccessoryStore = ComposerAccessoryStore()

        return SuperBibleAppDependencies(
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
            eventBus: eventBus,
            appletRegistry: appletRegistry,
            appleFoundationAvailability: bootAvailability,
            appleFoundationStatusProvider: appleStatusProvider,
            bibleAnnotateDispatcher: bibleAnnotateDispatcher,
            appletSettingsContributions: bibleSettingsContributions,
            bulkAnnotationBackground: bulkWiring?.background,
            composerAccessoryStore: composerAccessoryStore,
            hapticsEngine: hapticsEngine
        )
    }
}
