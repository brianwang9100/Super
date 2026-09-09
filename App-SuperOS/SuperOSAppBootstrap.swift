import Bible
import Chat
import Core
import Foundation
import FoundationModels
import SwiftUI
import Todo

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
    let registeredToolIDs: [String]
    let todoDependencies: TodoDependencies
    let eventBus: SuperEventBus
    /// One roster drives both the sidebar and the applet briefings supplied to Chat.
    let appletRegistry: AppletRegistry
    /// Reuse boot-time availability so mid-session Apple Intelligence changes cannot
    /// make the UI disagree with the seeder and provider hydrator.
    let appleFoundationAvailability: AppleFoundationAvailability
    /// Retain the dispatcher for the app session; deallocation ends its bus subscription.
    let bibleAnnotateDispatcher: BibleAnnotateDispatcher
    let hapticsEngine: any HapticsEngine

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
            hapticsEngine: hapticsEngine,
            launchBehavior: .standard,
            // The Bible reader keeps chapter controls in its own navigation bar on SuperOS.
            composerAccessoryStore: nil
        )
    }
}

enum SuperOSAppBootstrap {
    /// Defaults storage to this target's Application Support/Super directory.
    /// Database and filesystem setup errors propagate; tests may inject storage and Keychain.
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
        await AppBootstrapSupport.recoverModelAPIKeys(from: modelConfigRepo)
        let settingRepo = GRDBSettingRepository(database: database)
        let toolEnablementRepository = GRDBToolEnablementRepository(database: database)
        let memoryRepository = GRDBMemoryRepository(database: database)

        let toolRegistry = ToolRegistry(enablementRepository: toolEnablementRepository)
        await toolRegistry.register(TimeNowTool.registration())
        await toolRegistry.register(MemoryTool.registration(repository: memoryRepository))

        // Construct Bible before registering annotation tools. Struct copies share its inbox;
        // the stamp provider reads the active model after hydration, at execution time.
        let llmProviderRegistry = LLMProviderRegistry()

        let hapticsEngine = SystemHapticsEngine()

        let bibleApplet = BibleApplet(hapticsEngine: hapticsEngine)
        await bibleApplet.registerAnnotationTool(
            in: toolRegistry,
            stampProvider: ActiveModelBibleAnnotationStampProvider(registry: llmProviderRegistry)
        )
        await bibleApplet.registerNoteTool(in: toolRegistry)
        await bibleApplet.registerHighlightTool(in: toolRegistry)
        await bibleApplet.registerLookupTool(in: toolRegistry)

        let todoApplet = TodoApplet(dependencies: todoDependencies)
        await todoApplet.registerCreateTool(in: toolRegistry)

        // Seeding is best-effort so a transient failure does not prevent launch.
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

        #if DEBUG
        // A failed debug seed should only omit picker entries, not crash bootstrap.
        do {
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
            appleFoundationAvailability: bootAvailability
        )

        let compactor = Compactor(
            llmProviderRegistry: llmProviderRegistry,
            checkpointRepository: checkpointRepo
        )

        // Load persisted settings before creating sessions. ChatSettingsStore is stateless;
        // share its instance with Settings if caching is ever introduced.
        let initialSettings = await ChatSettingsStore(repository: settingRepo).load()

        let applets: [any MiniApplet] = [
            // Sidebar order is independent of the explicit Todo fallback below.
            ChatsApplet(chatDatabase: database),
            todoApplet,
            RecipesPlaceholderApplet(),
            bibleApplet,
            FinancePlaceholderApplet(),
        ]
        // Restore a registered backdrop, otherwise use Todo regardless of sidebar order.
        let resolvedID = AppletRegistry.resolveActiveID(
            applets: applets,
            storedID: UserDefaults.standard.string(forKey: AppShell.activeAppletStorageKey),
            fallbackID: TodoApplet.appletID
        )
        let appletRegistry = AppletRegistry(
            applets: applets,
            initialActiveID: resolvedID
        )

        let appletBriefings = appletRegistry.resolvedBriefings()
        // Load through ChatBriefing so resources resolve inside Chat's SwiftPM bundle.
        let chatBriefing = ChatBriefing.load()
        let compactChatBriefing = ChatBriefing.loadCompact()

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
            // Read the active applet live for compact-tier briefings.
            activeAppletID: { await appletRegistry.activeID },
            userPersonalization: initialSettings.userPersonalization,
            memoryRepository: memoryRepository,
            webSearchFulfiller: webSearchFulfiller
        )

        // Repair stranded tool calls before sessions can replay provider-invalid history.
        await chatSessionStore.recoverInterruptedToolCalls()

        let registeredToolIDs = await toolRegistry.allRegistrations().map(\.tool.id)

        // Subscribe Bible before exposing the bus to the shell and its deep-link routes.
        let eventBus = SuperEventBus()
        await bibleApplet.attach(to: eventBus)

        // Restrict headless sessions to bible.annotate with their own tool registry.
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
            bibleAnnotateDispatcher: bibleAnnotateDispatcher,
            hapticsEngine: hapticsEngine
        )
    }

}
