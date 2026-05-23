import Bible
import Chat
import Core
import Foundation
import FoundationModels
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

        // Fresh-install convenience: if the user has no configured
        // models AND the device can actually run AFM, seed a default
        // Apple-Foundation-Model row so Chat opens onto a usable
        // provider instead of the `noModelConfigured` empty state.
        // Already-populated DBs are left alone; a user who manually
        // deleted AFM gets it back only if they wipe the whole table
        // (deliberate — see `ModelConfigurationSeeding`).
        //
        // Gating on availability avoids showing an unusable AFM card on
        // ineligible devices. Phase 6 will render the availability
        // reason in the Settings subtitle so the row can re-appear with
        // a proper "Apple Intelligence isn't available" explanation;
        // until then, ineligible devices stay on the empty-state path
        // they already had.
        //
        // The seed is best-effort: a transient SQLite error here must
        // not lock the user out of the entire app, so the call is
        // isolated in its own `do/catch`. Worst case is the user lands
        // on `noModelConfigured` and adds a model manually, which is
        // the pre-AFM behavior anyway.
        let bootAvailability = AppleFoundationAvailability(
            SystemLanguageModel.default.availability
        )
        if bootAvailability.isAvailable {
            do {
                try await ModelConfigurationSeeding.seedDefaultIfEmpty(
                    repository: modelConfigRepo
                )
            } catch {
                // Intentional swallow: the seed is decorative. Other
                // bootstrap steps remain throwing so a genuine
                // database-open failure still surfaces.
                _ = error
            }
        }

        let llmProviderRegistry = LLMProviderRegistry()
        try await hydrateProviders(
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
    /// from the Keychain, and register the right `LLMProvider` for each
    /// row's `kind`. Registration order is creation-stable; the selected
    /// row is then promoted via `setActive(id:)` so the bootstrap doesn't
    /// depend on `LLMProviderRegistry`'s implementation detail of "first
    /// registered = active". An `.openAICompatible` row whose Keychain
    /// entry has been wiped registers anyway with a nil key — local
    /// servers (MLX, Ollama) don't require auth. An `.appleFoundation`
    /// row is only registered when the OS reports AFM as available; an
    /// unavailable device leaves the registry empty and the orchestrator
    /// falls back to its `noModelConfigured` banner.
    private static func hydrateProviders(
        into registry: LLMProviderRegistry,
        from repository: any ModelConfigurationRepository,
        toolRegistry: ToolRegistry,
        appleFoundationAvailability: AppleFoundationAvailability
    ) async throws {
        let configurations = try await repository.all()
        guard !configurations.isEmpty else { return }

        let http = URLSessionHTTPClient()
        let ordered = configurations.sorted { $0.createdAt < $1.createdAt }
        for record in ordered {
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
                // If AFM is unavailable right now the row stays in the
                // model list (Settings surfaces the reason once Phase
                // 6 lands), but no provider is registered for it; the
                // orchestrator surfaces `noModelConfigured` until the
                // user adds another model.
                //
                // `id` must match the row's UUID — `setActive(id:)`
                // below looks providers up by that identifier, so
                // registering AFM under the static `"apple-foundation"`
                // would silently fail to promote the seeded
                // `isSelected = true` row.
                guard appleFoundationAvailability.isAvailable else { continue }
                let provider = AppleFoundationLLMProvider(
                    id: record.id,
                    availability: appleFoundationAvailability,
                    toolRegistry: toolRegistry
                )
                await registry.register(provider)
            }
        }

        if let selectedId = try await repository.selected()?.id {
            // The only failure mode is `unknownProvider`, which can only
            // happen if the selected row's kind was unavailable (AFM on
            // an ineligible device) and skipped above. The
            // first-registered fallback (or "no provider" empty state)
            // is the right behavior in that case.
            try? await registry.setActive(id: selectedId)
        }
    }

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
