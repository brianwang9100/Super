import Bible
import Chat
import Core
import Foundation
import FoundationModels
import SwiftUI

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
    /// Retain the dispatcher for the app session; deallocation ends its bus subscription.
    let bibleAnnotateDispatcher: BibleAnnotateDispatcher

    /// Exposes Bible settings to Chat without a cross-applet import.
    let appletSettingsContributions: [AppletSettingsContribution]

    /// Outlives the Settings screen; nil when Bible's database could not open.
    let bulkAnnotationBackground: BulkAnnotationBackgroundScheduler?

    /// Shared by the Bible reader and shell for composer-accessory publication.
    let composerAccessoryStore: ComposerAccessoryStore

    let hapticsEngine: any HapticsEngine
    let providerAudioSetup: ProviderAudioSetup?
    let audioActivity: AudioActivity

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
            // Cold launch shows Bible with Chat minimized; foreground returns retain shell state.
            launchBehavior: AppShellLaunchBehavior(initialChatState: .minimized),
            composerAccessoryStore: composerAccessoryStore,
            providerAudioSetup: providerAudioSetup,
            audioActivity: audioActivity
        )
    }
}

enum SuperBibleAppBootstrap {
    /// Defaults storage to this target's Application Support/Super directory.
    /// Database and filesystem setup errors propagate; tests may inject storage and Keychain.
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
        await AppBootstrapSupport.recoverModelAPIKeys(from: modelConfigRepo)
        let settingRepo = GRDBSettingRepository(database: database)
        let toolEnablementRepository = GRDBToolEnablementRepository(database: database)
        let memoryRepository = GRDBMemoryRepository(database: database)

        let toolRegistry = ToolRegistry(enablementRepository: toolEnablementRepository)
        await toolRegistry.register(TimeNowTool.registration())
        await toolRegistry.register(MemoryTool.registration(repository: memoryRepository))

        // Construct Bible before registering annotation tools. The stamp provider reads the
        // active model at execution time, after provider hydration.
        let llmProviderRegistry = LLMProviderRegistry()

        let hapticsEngine = SystemHapticsEngine()

        let bibleApplet = BibleApplet(hapticsEngine: hapticsEngine)
        let audioActivity = AudioActivity()
        let audioCache = try NarrationAudioCache.openOrInMemory()
        let narration = bibleApplet.configureNarration(
            keychain: keychain,
            generator: OpenAISpeechGenerator(http: URLSessionHTTPClient(allowsRedirects: false)),
            cache: audioCache, audioActivity: audioActivity,
            listSources: {
                let rows = (try? await modelConfigRepo.all()) ?? []
                return rows.compactMap { row in
                    guard ProviderAudioCredential.isDirectOpenAI(providerId: row.providerId, baseURL: row.baseURL),
                          let ref = row.apiKeyRef else { return nil }
                    return ProviderAudioCredential(id: row.id, name: row.name, keyRef: ref)
                }
            }
        )
        await bibleApplet.registerAnnotationTool(
            in: toolRegistry,
            stampProvider: ActiveModelBibleAnnotationStampProvider(registry: llmProviderRegistry)
        )
        await bibleApplet.registerNoteTool(in: toolRegistry)
        await bibleApplet.registerHighlightTool(in: toolRegistry)
        await bibleApplet.registerLookupTool(in: toolRegistry)

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

        let initialSettings = await ChatSettingsStore(repository: settingRepo).load()

        // Array order controls the sidebar; initialActiveID independently selects the launch backdrop.
        let applets: [any MiniApplet] = [
            ChatsApplet(chatDatabase: database),
            bibleApplet,
            // Share Bible's database through a read-only context without exposing its internal database type.
            bibleApplet.makeBookmarksApplet(),
        ]
        // Ignore saved backdrop selection on cold launch. Pair Bible with the minimized chat launch state.
        let appletRegistry = AppletRegistry(
            applets: applets,
            initialActiveID: BibleApplet.appletID
        )

        let appletBriefings = appletRegistry.resolvedBriefings()
        // Load the app-bundled Bible persona; ChatBriefing would load the generic package persona.
        let chatBriefing = SuperBibleSystemPromptLoader.load()
        let compactChatBriefing = SuperBibleSystemPromptLoader.loadCompact()

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

        // Bulk dispatch uses a separate userBulk stamp and is called directly by the runner.
        // Do not attach it to the event bus used by interactive annotation requests.
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

        // Settings and background processing share one runner so work outlives the settings screen.
        let bulkWiring = bibleApplet.makeBulkAnnotationWiring(
            requiresCostConfirmation: true,
            generator: bibleBulkAnnotateDispatcher,
            currentModelID: { await llmProviderRegistry.activeID() ?? "" }
        )
        let bibleSettingsContributions = (bulkWiring.map { [$0.settingsContribution] } ?? []) + (narration.map { [$0.contribution] } ?? [])

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
            bibleAnnotateDispatcher: bibleAnnotateDispatcher,
            appletSettingsContributions: bibleSettingsContributions,
            bulkAnnotationBackground: bulkWiring?.background,
            composerAccessoryStore: composerAccessoryStore,
            hapticsEngine: hapticsEngine,
            providerAudioSetup: narration?.setup,
            audioActivity: audioActivity
        )
    }
}
