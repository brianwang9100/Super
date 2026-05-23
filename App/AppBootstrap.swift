import Bible
import Chat
import Core
import Foundation
import SwiftUI
import Todo

/// Wired-up dependency graph the Shell hands to its views.
///
/// Constructed exactly once on app launch by `AppBootstrap.bootstrap()`. The
/// Shell stores it in app state and injects the pieces individual views need
/// via `@Environment` (UI wiring lands in M7).
@MainActor
struct AppDependencies {
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
}

/// One-shot composition root. Bootstraps the on-disk database, every
/// repository, the tool/provider registries, and the `ChatSessionStore`.
///
/// Lives in `App/` (not in any package) because it pulls together pieces
/// from both Core and Chat — i.e. it is the place those modules first meet.
enum AppBootstrap {
    /// `UserDefaults` key for the persisted backdrop applet ID. Owned here
    /// (rather than in `AppShell`) now that the registry is built during
    /// bootstrap — the read and the write must agree on the key or
    /// persistence silently breaks.
    static let activeAppletStorageKey: String = "shell.activeAppletID"

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
    ) async throws -> AppDependencies {
        let dataDirectory = try directory ?? defaultDataDirectory()
        try ensureDirectoryExists(dataDirectory)

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

        let llmProviderRegistry = LLMProviderRegistry()
        #if DEBUG
        try await seedDebugModelIfNeeded(repository: modelConfigRepo)
        #endif
        try await hydrateProviders(
            into: llmProviderRegistry,
            from: modelConfigRepo
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
            TodoApplet(dependencies: todoDependencies),
            RecipesPlaceholderApplet(),
            BibleApplet(),
            FinancePlaceholderApplet(),
        ]
        // Resolve the persisted active backdrop here (was in
        // `AppShell.init`). Fallback chain keeps the invariant that
        // some backdrop is always selected: persisted id if it still
        // matches a registered applet, else the first applet.
        let storedID = UserDefaults.standard.string(forKey: activeAppletStorageKey)
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
        // The Chat-assistant base prompt is the renamed
        // `DefaultSystemPrompt.md` resource. Loaded through
        // `ChatApplet().systemPrompt` so the lookup runs against
        // *Chat's* bundle — calling `AppletSystemPrompt.load(from:
        // .module, ...)` directly from `App/` would resolve to the App
        // target's bundle, which doesn't ship the markdown.
        let chatBriefing = ChatApplet().systemPrompt

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

        return AppDependencies(
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
            appletRegistry: appletRegistry
        )
    }

    /// Read every persisted `ModelConfigurationRecord`, resolve its API key
    /// from the Keychain, and register an `OpenAICompatibleLLMProvider` for
    /// each. Registration order is creation-stable; the selected row is then
    /// promoted via `setActive(id:)` so the bootstrap doesn't depend on
    /// `LLMProviderRegistry`'s implementation detail of "first registered =
    /// active". A row whose Keychain entry has been wiped registers anyway
    /// with a nil key — local servers (MLX, Ollama) don't require auth.
    private static func hydrateProviders(
        into registry: LLMProviderRegistry,
        from repository: any ModelConfigurationRepository
    ) async throws {
        let configurations = try await repository.all()
        guard !configurations.isEmpty else { return }

        let http = URLSessionHTTPClient()
        let ordered = configurations.sorted { $0.createdAt < $1.createdAt }
        for record in ordered {
            // Unrouted kinds surface as `noModelConfigured` — deliberate no-op, not fallthrough.
            switch record.kind {
            case .openAICompatible:
                let apiKey: String?
                if let ref = record.apiKeyRef {
                    apiKey = try? await repository.loadAPIKey(ref: ref)
                } else {
                    apiKey = nil
                }
                let provider = OpenAICompatibleLLMProvider(
                    configuration: record.configuration,
                    apiKey: apiKey,
                    http: http
                )
                await registry.register(provider)
            case .appleFoundation:
                break // `AppleFoundationLLMProvider` will register here once that class lands.
            #if DEBUG
            case .debug:
                await registry.register(DebugLLMProvider())
            #endif
            }
        }

        if let selectedId = try await repository.selected()?.id {
            // The only failure mode is `unknownProvider`, which can only
            // happen if the row was deleted between `selected()` and the
            // loop above — at which point the first-registered fallback is
            // the right behavior anyway.
            try? await registry.setActive(id: selectedId)
        }
    }

    #if DEBUG
    /// DEBUG-only first-launch seed: insert a `ModelConfigurationRecord`
    /// with `kind = .debug` so `DebugLLMProvider` shows up in the model
    /// picker without the user having to add a model manually. Idempotent
    /// — does nothing if a debug row already exists. The row is marked
    /// selected only if no other row is selected, so a developer who has
    /// already wired a real OpenAI-compatible model keeps it as the
    /// active model and just sees the debug entry as an alternative.
    private static func seedDebugModelIfNeeded(
        repository: any ModelConfigurationRepository
    ) async throws {
        let existing = try await repository.all()
        if existing.contains(where: { $0.kind == .debug }) { return }
        let shouldSelect = try await repository.selected() == nil
        let record = ModelConfigurationRecord(
            id: "debug-canned",
            name: "Debug (canned)",
            baseURL: nil,
            apiKeyRef: nil,
            modelId: DebugLLMProvider.modelID,
            createdAt: Date(),
            kind: .debug,
            supportsThinking: true,
            maxContextTokens: DebugLLMProvider.maxContextTokens,
            isSelected: shouldSelect
        )
        try await repository.save(record)
    }
    #endif

    private static func defaultDataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "Super", directoryHint: .isDirectory)
    }

    /// Create `url` (and any missing parents) and pin its file-protection
    /// class to `.complete`. Files created inside inherit the directory's
    /// class by default, so this also covers the SQLite sidecar files
    /// (`-wal`, `-shm`, `-journal`) that GRDB may produce mid-transaction.
    /// Best-effort: the protection attribute is iOS-enforced; macOS test
    /// runs silently no-op.
    private static func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }
}
