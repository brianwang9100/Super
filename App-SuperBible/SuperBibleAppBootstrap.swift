import Bible
import Chat
import Core
import Foundation
import FoundationModels
import SwiftUI

/// Wired-up dependency graph the SuperBible shell hands to its views.
///
/// Mirrors `AppDependencies` (the SuperOS sibling) field-for-field on the
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

    /// Slice handed to `AppShell`. Matches `AppDependencies.shellDependencies`
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
            // SuperBible v1 ships without user identity (no accounts, no
            // server — see App-SuperBible/AGENTS.md § Local-only v1).
            // Sidebar header + Settings account row render with empty
            // strings; real identity arrives with SB-M3+ Sign in with
            // Apple per the fork spec §7.
            userInitials: "",
            userName: "",
            accountEmail: ""
        )
    }
}

/// One-shot composition root for the SuperBible target. Stays separate
/// from `SuperOSAppBootstrap` because the two apps register different
/// applet sets — but the generic plumbing (directory creation, provider
/// hydration, debug-model seed) is shared through `AppBootstrapHelpers`.
///
/// Lives in `App-SuperBible/` for symmetry with
/// `App/SuperOSAppBootstrap.swift`. Both files compile in their owner
/// target only; `App/Shell/` content (`AppShell`, `AppShellDependencies`,
/// `AppBootstrapHelpers`) is what crosses into the SuperBible target via
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
        let dataDirectory = try directory ?? AppBootstrapHelpers.defaultDataDirectory()
        try AppBootstrapHelpers.ensureDirectoryExists(dataDirectory)

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

        // Best-effort AFM seed, same shape as SuperOS — skipped on
        // ineligible devices and pre-populated DBs.
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
        do {
            try await AppBootstrapHelpers.seedDebugModelIfNeeded(repository: modelConfigRepo)
        } catch {
            print("[DebugLLMProvider] seed failed: \(error)")
        }
        #endif
        try await AppBootstrapHelpers.hydrateProviders(
            into: llmProviderRegistry,
            from: modelConfigRepo,
            toolRegistry: toolRegistry,
            appleFoundationAvailability: bootAvailability
        )

        let compactor = Compactor(
            llmProviderRegistry: llmProviderRegistry,
            checkpointRepository: checkpointRepo
        )

        let initialSettings = await ChatSettingsStore(repository: settingRepo).load()

        // SuperBible v1 applet set: Bible only at SB-M1. Plans joins at
        // SB-M2; no Todo or productivity-style placeholders ever
        // (per `App-SuperBible/AGENTS.md` § Module identity).
        let applets: [any MiniApplet] = [
            BibleApplet(),
        ]
        let storedID = UserDefaults.standard.string(forKey: AppShell.activeAppletStorageKey)
        let resolvedID = applets.first(where: { $0.appletID == storedID })?.appletID
            ?? applets.first?.appletID
        let appletRegistry = AppletRegistry(
            applets: applets,
            initialActiveID: resolvedID
        )

        // Per-applet briefings via the same `resolvedBriefings()` helper
        // SuperOS uses — sorted by `appletID`, empty bodies skipped.
        let appletBriefings = appletRegistry.resolvedBriefings()
        // The SuperBible-flavor Chat-assistant base prompt. Reads
        // `Resources/SuperBibleSystemPrompt.md` from the App-SuperBible
        // target bundle (i.e., `Bundle.main`), not Chat's SwiftPM
        // bundle — `ChatApplet().systemPrompt` would otherwise return
        // Chat's generic `DefaultSystemPrompt.md`.
        let chatBriefing = SuperBibleSystemPromptLoader.load()

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
            eventBus: SuperEventBus(),
            appletRegistry: appletRegistry,
            appleFoundationAvailability: bootAvailability
        )
    }
}
