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
            // SuperOS is a single-user dev MVP — hard-code the founder.
            // SuperBible supplies empty strings instead (no user identity yet).
            userInitials: "BW",
            userName: "Brian Wang",
            accountEmail: "brianwang9100@gmail.com",
            // SuperOS keeps the standard launch policy: chat opens
            // expanded over the user's last-used applet (restored by
            // `UserDefaults` lookup further down in `bootstrap()`).
            launchBehavior: .standard
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

        // Best-effort: seed an AFM row for fresh installs so Chat opens
        // onto a usable provider. Skipped on ineligible devices and
        // pre-populated DBs; errors swallowed so a transient SQLite
        // failure can't take down the whole bootstrap.
        let bootAvailability = AppleFoundationAvailability(
            SystemLanguageModel.default.availability
        )
        if bootAvailability.isAvailable {
            do {
                try await ModelConfigurationSeeding.seedDefaultIfEmpty(
                    repository: modelConfigRepo
                )
            } catch {
                #if DEBUG
                assertionFailure("ModelConfigurationSeeding failed: \(error)")
                #endif
            }
        }

        let llmProviderRegistry = LLMProviderRegistry()
        #if DEBUG
        // Swallow seed failures: a transient GRDB error here (WAL
        // contention, full disk) should *not* crash bootstrap on a
        // simulator — the debug provider just doesn't show up in the
        // picker until the next launch. Mirrors the do/catch the
        // production AFM seed above uses, but with `print` instead of
        // `assertionFailure` so dev-loop annoyance is bounded to a log
        // line rather than a hard trap.
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
            appleFoundationAvailability: bootAvailability
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
        let applets: [any MiniApplet] = [
            // Order is load-bearing: the first applet is the cold-start
            // default on a fresh install (no `activeAppletStorageKey`
            // in `UserDefaults`). Keep `TodoApplet` first so Todo
            // remains the default landing surface — `ChatsApplet`
            // sits second as a recently-added rail entry that the
            // user can pin via `onSelectApplet`.
            TodoApplet(dependencies: todoDependencies),
            ChatsApplet(chatDatabase: database),
            RecipesPlaceholderApplet(),
            BibleApplet(),
            FinancePlaceholderApplet(),
        ]
        // Resolve the persisted active backdrop here (was in
        // `AppShell.init`). Fallback chain keeps the invariant that
        // some backdrop is always selected: persisted id if it still
        // matches a registered applet, else the first applet.
        let storedID = UserDefaults.standard.string(forKey: AppShell.activeAppletStorageKey)
        let resolvedID = applets.first(where: { $0.appletID == storedID })?.appletID
            ?? applets.first?.appletID
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
        let chatBriefing = ChatBriefing.load()

        let chatSessionStore = ChatSessionStore(
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmProviderRegistry,
            toolRegistry: toolRegistry,
            compactor: compactor,
            autoCompactEnabled: initialSettings.autoCompactEnabled,
            autoCompactThreshold: initialSettings.autoCompactThreshold,
            chatBriefing: chatBriefing,
            appletBriefings: appletBriefings,
            userPersonalization: initialSettings.userPersonalization,
            memoryRepository: memoryRepository
        )

        let registeredToolIDs = await toolRegistry.allRegistrations().map(\.tool.id)

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
            eventBus: SuperEventBus(),
            appletRegistry: appletRegistry,
            appleFoundationAvailability: bootAvailability
        )
    }

}
