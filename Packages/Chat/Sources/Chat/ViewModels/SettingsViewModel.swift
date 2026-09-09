import Core
import Foundation
import FoundationModels
import os
import SwiftUI

private let chatSettingsLog = Logger(subsystem: "com.brianwang.Super", category: "chat-settings")

/// A model edit failed, and its unused staged secret could not be removed from Keychain.
private enum ModelCredentialSaveError: Error, Sendable {
    case stagedKeyCleanupFailed
}

@MainActor
@Observable
public final class SettingsViewModel {
    public struct ModelRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: LLMProviderKind
        public let name: String
        public let monogram: String
        public let endpoint: String
        public let maxContextTokens: Int
        public var isEnabled: Bool
        public let baseURL: URL?
        public let modelId: String
        public let supportsThinking: Bool
        /// Resolve key presence before rendering to avoid an empty SecureField flicker.
        public let hasAPIKey: Bool
        public let providerId: String?
        public let searchBackend: String?

        public init(
            id: String,
            name: String,
            monogram: String,
            endpoint: String,
            maxContextTokens: Int,
            isEnabled: Bool,
            kind: LLMProviderKind = .openAICompatible,
            baseURL: URL? = nil,
            modelId: String = "",
            supportsThinking: Bool = false,
            hasAPIKey: Bool = false,
            searchBackend: String? = nil,
            providerId: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.monogram = monogram
            self.endpoint = endpoint
            self.maxContextTokens = maxContextTokens
            self.isEnabled = isEnabled
            self.baseURL = baseURL
            self.modelId = modelId
            self.supportsThinking = supportsThinking
            self.hasAPIKey = hasAPIKey
            self.searchBackend = searchBackend
            self.providerId = providerId
        }
    }

    public struct ToolRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let summary: String
        public var isEnabled: Bool
        public let configPane: SettingsSheet.Pane?

        public init(
            id: String,
            name: String,
            summary: String,
            isEnabled: Bool,
            configPane: SettingsSheet.Pane? = nil
        ) {
            self.id = id
            self.name = name
            self.summary = summary
            self.isEnabled = isEnabled
            self.configPane = configPane
        }
    }

    public private(set) var settings: ChatSettings = .default

    public private(set) var models: [ModelRow] = []

    public private(set) var tools: [ToolRow] = []

    public private(set) var chatCount: Int = 0

    /// Inline model mutation error for the current form. Operations with an
    /// originating session cannot clear or replace another form's error.
    /// Non-form callers retain the latest-attempt error behavior.
    public private(set) var modelEditError: String?

    /// Session-only provider catalog cache; a missing entry uses the bundled catalog.
    public private(set) var fetchedModels: [String: [LLMCatalogModel]] = [:]

    public private(set) var loadingModelsProviderID: String?

    public private(set) var modelListNote: [String: String] = [:]

    /// Last-started fetch wins, preventing a slow stored-key request from overwriting a typed-key result.
    private var modelListFetchGeneration: [String: Int] = [:]

    public var navigationPath: [SettingsSheet.Pane] = [] {
        didSet {
            guard navigationPath != oldValue else { return }
            navigationGeneration += 1
            activeModelFormSession = nil
        }
    }

    /// Modal base pane; deep links can make a sub-pane the close-button root.
    public var rootPane: SettingsSheet.Pane = .root

    public let appInfo: SuperAppInfo

    public let audioSetup: ProviderAudioSetup?
    private let eventBus: SuperEventBus?
    public private(set) var lastSavedModel: ModelConfigurationRecord?
    private var modelMutationIDs: Set<String> = []
    private var modelFormGeneration = 0
    private var activeModelFormSession: Int?
    private var navigationGeneration = 0
    private var pendingPanePop: Task<Void, Never>?
    /// Test seam for holding the UIKit draft flush before a deferred navigation mutation.
    var flushPaneCleanup: @MainActor () async -> Void = { await Task.yield() }
    private let store: ChatSettingsStore
    private let modelRepository: any ModelConfigurationRepository
    private let conversationRepository: any ConversationRepository
    private let toolRegistry: ToolRegistry

    public let exportController: ChatExportController
    private let memoryRepository: (any MemoryRepository)?
    private let llmProviderRegistry: LLMProviderRegistry?
    private let httpClient: (any HTTPClient)?
    private let modelListingService: (any ModelListingService)?
    /// Require policy receivers so persisted edits cannot silently miss active sessions.
    private let userPersonalizationReceiver: any UserPersonalizationReceiver

    private let autoCompactPolicyReceiver: any AutoCompactPolicyReceiver

    private let webSearchPolicyReceiver: any WebSearchPolicyReceiver

    private let hapticsEngine: any HapticsEngine

    public var onModelsChanged: (@MainActor () -> Void)?

    /// Availability snapshot taken at initialization.
    public let appleFoundationAvailability: AppleFoundationAvailability

    public let appleFoundationContextTokens: Int

    public init(
        appInfo: SuperAppInfo,
        settingRepository: any SettingRepository,
        modelRepository: any ModelConfigurationRepository,
        conversationRepository: any ConversationRepository,
        toolRegistry: ToolRegistry,
        userPersonalizationReceiver: any UserPersonalizationReceiver,
        autoCompactPolicyReceiver: any AutoCompactPolicyReceiver,
        webSearchPolicyReceiver: any WebSearchPolicyReceiver,
        hapticsEngine: any HapticsEngine = NoOpHapticsEngine(),
        // Missing repositories give previews an inert exporter; production wires both.
        messageRepository: (any MessageRepository)? = nil,
        toolCallRepository: (any ToolCallRepository)? = nil,
        clock: any Clock = SystemClock(),
        memoryRepository: (any MemoryRepository)? = nil,
        llmProviderRegistry: LLMProviderRegistry? = nil,
        httpClient: (any HTTPClient)? = nil,
        modelListingService: (any ModelListingService)? = nil,
        appleFoundationAvailability: AppleFoundationAvailability = AppleFoundationAvailability(
            SystemLanguageModel.default.availability
        ),
        appleFoundationContextTokens: Int = AppleFoundationLLMProvider.deviceContextTokens,
        audioSetup: ProviderAudioSetup? = nil,
        eventBus: SuperEventBus? = nil
    ) {
        self.audioSetup = audioSetup
        self.eventBus = eventBus
        self.appInfo = appInfo
        self.store = ChatSettingsStore(repository: settingRepository)
        self.modelRepository = modelRepository
        self.conversationRepository = conversationRepository
        self.toolRegistry = toolRegistry
        let exporter: any ChatExporter
        if let messageRepository, let toolCallRepository {
            exporter = LiveChatExporter(
                conversationRepository: conversationRepository,
                messageRepository: messageRepository,
                toolCallRepository: toolCallRepository,
                clock: clock
            )
        } else {
            exporter = EmptyChatExporter(clock: clock)
        }
        self.exportController = ChatExportController(exporter: exporter, clock: clock)
        self.memoryRepository = memoryRepository
        self.llmProviderRegistry = llmProviderRegistry
        self.userPersonalizationReceiver = userPersonalizationReceiver
        self.autoCompactPolicyReceiver = autoCompactPolicyReceiver
        self.webSearchPolicyReceiver = webSearchPolicyReceiver
        self.hapticsEngine = hapticsEngine
        self.httpClient = httpClient
        self.modelListingService = modelListingService ?? httpClient.map { LiveModelListingService(http: $0) }
        self.appleFoundationAvailability = appleFoundationAvailability
        self.appleFoundationContextTokens = appleFoundationContextTokens
    }

    private var hasLoaded: Bool = false

    /// Seed snapshot state and suppress load so the sheet's task cannot overwrite it.
    func _setSnapshotState(
        settings: ChatSettings,
        models: [ModelRow] = [],
        tools: [ToolRow] = [],
        chatCount: Int = 0
    ) {
        self.settings = settings
        self.models = models
        self.tools = tools
        self.chatCount = chatCount
        self.hasLoaded = true
    }

    func _setModelListSnapshotState(
        fetchedModels: [String: [LLMCatalogModel]] = [:],
        loadingModelsProviderID: String? = nil,
        modelListNote: [String: String] = [:]
    ) {
        self.fetchedModels = fetchedModels
        self.loadingModelsProviderID = loadingModelsProviderID
        self.modelListNote = modelListNote
    }

    /// Load once, retaining defaults for failed reads.
    public func load() async {
        if hasLoaded { return }
        async let loadedSettings = store.load()
        async let modelsLoad: Void = loadModels()
        async let toolsLoad: Void = loadTools()
        async let countLoad: Void = loadChatCount()
        settings = await loadedSettings
        _ = await (modelsLoad, toolsLoad, countLoad)
        hasLoaded = true
    }

    private func loadModels() async {
        let records = (try? await modelRepository.all()) ?? []
        var rows: [ModelRow] = []
        for record in records {
            let stored = await store.isModelEnabled(id: record.id)
            let keyExists: Bool
            if let ref = record.apiKeyRef {
                keyExists = (try? await modelRepository.loadAPIKey(ref: ref)).flatMap { $0 } != nil
            } else {
                keyExists = false
            }
            rows.append(ModelRow(
                id: record.id,
                name: record.name,
                monogram: Self.monogram(for: record.name),
                endpoint: record.baseURL.map(Self.shortEndpoint) ?? "",
                maxContextTokens: record.maxContextTokens,
                isEnabled: stored ?? true,
                kind: record.kind,
                baseURL: record.baseURL,
                modelId: record.modelId,
                supportsThinking: record.supportsThinking,
                hasAPIKey: keyExists,
                searchBackend: record.searchBackend,
                providerId: record.providerId
            ))
        }
        models = rows
    }

    /// Reuse cached lists unless forced. Missing credentials or unsupported providers skip fetching.
    /// Empty or failed results clear the cache so the displayed list matches the fallback note.
    public func loadAvailableModels(providerID: String, apiKey: String?, force: Bool) async {
        guard let service = modelListingService else { return }
        if !force, fetchedModels[providerID] != nil { return }
        let key = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard let entry = LLMProviderCatalog.entry(forID: providerID),
              let baseURL = entry.defaultBaseURL else { return }

        loadingModelsProviderID = providerID
        let generation = (modelListFetchGeneration[providerID] ?? 0) + 1
        modelListFetchGeneration[providerID] = generation
        // A different provider must not clear this spinner. Same-provider fetches still share it.
        defer { if loadingModelsProviderID == providerID { loadingModelsProviderID = nil } }
        do {
            let ids = try await service.listModelIDs(kind: entry.kind, baseURL: baseURL, apiKey: key)
            guard modelListFetchGeneration[providerID] == generation else { return }
            let reconciled = LLMProviderCatalog.reconcile(providerID: providerID, fetchedModelIDs: ids)
            if reconciled.isEmpty {
                fetchedModels[providerID] = nil
                modelListNote[providerID] = Self.modelListFallbackNote
            } else {
                fetchedModels[providerID] = reconciled
                modelListNote[providerID] = nil
            }
        } catch {
            // The listing service wraps cancellation as transport failure; check the task
            // to avoid flashing a fallback error while the user types.
            guard !Task.isCancelled else { return }
            guard modelListFetchGeneration[providerID] == generation else { return }
            fetchedModels[providerID] = nil
            modelListNote[providerID] = Self.modelListFallbackNote
        }
    }

    /// Use the stored key while the form displays placeholder bullets. Missing credentials
    /// silently skip passive loads; an explicit refresh shows the fallback note.
    public func loadAvailableModelsUsingStoredKey(
        providerID: String,
        editingModelID: String,
        force: Bool
    ) async {
        guard modelListingService != nil else { return }
        if !force, fetchedModels[providerID] != nil { return }
        guard let record = try? await modelRepository.fetch(id: editingModelID),
              let ref = record.apiKeyRef,
              let key = try? await modelRepository.loadAPIKey(ref: ref),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            if force { modelListNote[providerID] = Self.modelListFallbackNote }
            return
        }
        await loadAvailableModels(providerID: providerID, apiKey: key, force: force)
    }

    static let modelListFallbackNote = "Couldn't load live models — showing built-in list."

    private func loadTools() async {
        let registrations = await toolRegistry.allRegistrations()
        tools = registrations.map { reg in
            ToolRow(
                id: reg.tool.id,
                // Use display copy, never the LLM-facing tool description.
                name: reg.tool.displayName ?? reg.tool.name,
                summary: reg.tool.summary ?? "",
                isEnabled: reg.isEnabled,
                configPane: Self.configPane(forToolID: reg.tool.id)
            )
        }
    }

    /// Pane identity belongs in Chat UI, not Core's ToolRegistration.
    private static func configPane(forToolID id: String) -> SettingsSheet.Pane? {
        switch id {
        case MemoryTool.toolID: return .memory
        default: return nil
        }
    }

    private func loadChatCount() async {
        let rows = (try? await conversationRepository.listActive()) ?? []
        chatCount = rows.count
    }

    public func setTheme(_ id: ChatSettings.ThemeID) async {
        settings.themeId = id
        try? await store.setTheme(id)
    }

    public func setUserPersonalization(_ value: String) async {
        settings.userPersonalization = value
        try? await store.setUserPersonalization(value)
        await userPersonalizationReceiver.setUserPersonalization(value)
    }

    public func setDefaultVerbosity(_ value: ChatVerbosity) async {
        settings.defaultVerbosity = value
        try? await store.setDefaultVerbosity(value)
    }

    public func setFontScale(_ value: Double) async {
        let clamped = ChatSettings.clampFontScale(value)
        settings.fontScale = clamped
        try? await store.setFontScale(clamped)
    }

    public func setAutoCompactEnabled(_ value: Bool) async {
        settings.autoCompactEnabled = value
        try? await store.setAutoCompactEnabled(value)
        await autoCompactPolicyReceiver.setAutoCompactPolicy(
            enabled: settings.autoCompactEnabled,
            threshold: settings.autoCompactThreshold
        )
    }

    public func setAutoCompactThreshold(_ value: Double) async {
        let clamped = ChatSettings.clampThreshold(value)
        settings.autoCompactThreshold = clamped
        try? await store.setAutoCompactThreshold(clamped)
        await autoCompactPolicyReceiver.setAutoCompactPolicy(
            enabled: settings.autoCompactEnabled,
            threshold: settings.autoCompactThreshold
        )
    }

    public func setAskBeforeSearching(_ value: Bool) async {
        settings.askBeforeSearching = value
        try? await store.setAskBeforeSearching(value)
        await webSearchPolicyReceiver.setAskBeforeSearching(value)
    }

    /// TitleGenerator reads fresh settings per request, so no session fan-out is needed.
    public func setSummarizeTitlesEnabled(_ value: Bool) async {
        settings.summarizeTitlesEnabled = value
        try? await store.setSummarizeTitlesEnabled(value)
    }

    public func setHapticsEnabled(_ value: Bool) async {
        settings.hapticsEnabled = value
        hapticsEngine.setEnabled(value)
        try? await store.setHapticsEnabled(value)
    }

    /// Pass a model record ID, not a shared upstream model ID; nil selects automatic AFM.
    public func setTitleModelId(_ id: String?) async {
        settings.titleModelId = id
        try? await store.setTitleModelId(id)
    }

    public func setModelEnabled(id: String, enabled: Bool) async {
        if let idx = models.firstIndex(where: { $0.id == id }) {
            models[idx].isEnabled = enabled
        }
        try? await store.setModelEnabled(id: id, enabled: enabled)
    }

    public func setLastSelectedModelId(_ id: String) async {
        settings.lastSelectedModelId = id
        try? await store.setLastSelectedModelId(id)
    }

    public func openPane(_ pane: SettingsSheet.Pane) {
        guard pane != .root else {
            popToRoot()
            return
        }
        navigationPath.append(pane)
    }

    /// Flush pane cleanup to UIKit before changing the path, preventing a discarded
    /// SecureField from triggering Save Password on dismissal.
    public func popPane() {
        activeModelFormSession = nil
        navigationGeneration += 1
        let generation = navigationGeneration
        if let cleanup = beforePopCleanup {
            beforePopCleanup = nil
            cleanup()
            pendingPanePop = Task { @MainActor in
                await flushPaneCleanup()
                guard navigationGeneration == generation, !navigationPath.isEmpty else { return }
                navigationPath.removeLast()
            }
        } else {
            guard !navigationPath.isEmpty else { return }
            navigationPath.removeLast()
        }
    }

    public func popToRoot() {
        activeModelFormSession = nil
        navigationGeneration += 1
        if let cleanup = beforePopCleanup {
            beforePopCleanup = nil
            cleanup()
        }
        navigationPath.removeAll()
    }

    /// Waits for the deferred draft flush in deterministic navigation tests.
    func waitForPendingPanePop() async { await pendingPanePop?.value }

    /// The active pane scrubs sensitive drafts before deferred navigation; see popPane().
    public var beforePopCleanup: (@MainActor () -> Void)?

    public var hasAppleFoundationModel: Bool {
        models.contains { $0.kind == .appleFoundation }
    }

    /// Return the committed row or nil on failure. A form session scopes error publication;
    /// AFM registration also depends on the initialization-time availability snapshot.
    @discardableResult
    public func createAppleFoundationModel(
        name: String,
        supportsThinking: Bool,
        maxContextTokens: Int,
        idGenerator: () -> String = { UUID().uuidString },
        now: Date = Date(),
        formSession: Int? = nil
    ) async -> ModelConfigurationRecord? {
        let recordId = idGenerator()
        guard modelMutationIDs.insert(recordId).inserted else { return nil }
        defer { modelMutationIDs.remove(recordId) }
        publishModelEditError(nil, formSession: formSession)
        lastSavedModel = nil
        do {
            let record = ModelConfigurationRecord(
                id: recordId,
                name: name,
                baseURL: nil,
                apiKeyRef: nil,
                modelId: "system-default",
                createdAt: now,
                kind: .appleFoundation,
                supportsThinking: supportsThinking,
                maxContextTokens: maxContextTokens,
                isSelected: false
            )
            try await modelRepository.save(record)
            lastSavedModel = record
            await registerProvider(for: record, apiKey: nil)
            await loadModels()
            onModelsChanged?()
            return record
        } catch {
            chatSettingsLog.error("createAppleFoundationModel failed: \(String(describing: error), privacy: .public)")
            publishModelEditError("Could not save model: \(error.localizedDescription)", formSession: formSession)
            await loadModels()
            return nil
        }
    }

    /// Persists a new model and returns its committed row, or nil on failure.
    /// A supplied form session owns error clearing and publication; credential cleanup always finishes.
    @discardableResult
    public func createModel(
        name: String,
        baseURL: URL,
        modelId: String,
        apiKey: String,
        supportsThinking: Bool,
        maxContextTokens: Int,
        kind: LLMProviderKind = .openAICompatible,
        searchBackend: String? = nil,
        providerId: String? = nil,
        idGenerator: () -> String = { UUID().uuidString },
        now: Date = Date(),
        formSession: Int? = nil
    ) async -> ModelConfigurationRecord? {
        let ref = idGenerator()
        let recordId = idGenerator()
        guard modelMutationIDs.insert(recordId).inserted else { return nil }
        defer { modelMutationIDs.remove(recordId) }
        publishModelEditError(nil, formSession: formSession)
        lastSavedModel = nil
        do {
            let record = ModelConfigurationRecord(
                id: recordId,
                name: name,
                baseURL: baseURL,
                apiKeyRef: ref,
                modelId: modelId,
                createdAt: now,
                kind: kind,
                supportsThinking: supportsThinking,
                maxContextTokens: maxContextTokens,
                isSelected: false,
                searchBackend: searchBackend,
                providerId: providerId
            )
            try await withStagedAPIKey(apiKey, ref: ref) { try await modelRepository.save(record) }
            lastSavedModel = record
            await eventBus?.publish(.credentialChanged(id: record.id))
            await registerProvider(for: record, apiKey: apiKey)
            await loadModels()
            onModelsChanged?()
            return record
        } catch {
            chatSettingsLog.error("createModel failed: \(String(describing: error), privacy: .public)")
            if error is ModelCredentialSaveError {
                publishModelEditError("Could not save model. An unused key could not be removed from secure storage. Restart the app to retry cleanup.", formSession: formSession)
            } else { publishModelEditError("Could not save model: \(error.localizedDescription)", formSession: formSession) }
            await loadModels()
            return nil
        }
    }

    /// Blank apiKey preserves the stored secret; nil searchSelection preserves kind and backend.
    /// Return the committed row or nil on failure/overlap. Form sessions scope errors,
    /// while accepted persistence and credential cleanup continue after dismissal.
    @discardableResult
    public func updateModel(
        id: String,
        name: String,
        baseURL: URL?,
        modelId: String,
        apiKey: String,
        supportsThinking: Bool,
        maxContextTokens: Int,
        searchSelection: (kind: LLMProviderKind, searchBackend: String?)? = nil,
        providerId: String? = nil,
        idGenerator: any IDGenerator = UUIDGenerator(),
        formSession: Int? = nil
    ) async -> ModelConfigurationRecord? {
        guard modelMutationIDs.insert(id).inserted else { return nil }
        defer { modelMutationIDs.remove(id) }
        publishModelEditError(nil, formSession: formSession)
        lastSavedModel = nil
        do {
            guard let existing = try await modelRepository.fetch(id: id) else {
                publishModelEditError("Could not save model: row no longer exists.", formSession: formSession)
                return nil
            }
            let targetKind = searchSelection?.kind ?? existing.kind
            let targetSearchBackend = searchSelection.map(\.searchBackend) ?? existing.searchBackend
            let nextBaseURL: URL?
            switch targetKind {
            case .openAICompatible, .anthropicNative, .geminiNative, .openAIResponses:
                // Nil means no URL edit; preserve the stored endpoint.
                nextBaseURL = baseURL ?? existing.baseURL
            case .appleFoundation:
                nextBaseURL = existing.baseURL
            #if DEBUG
            case .debug:
                nextBaseURL = existing.baseURL
            #endif
            }
            let updated = ModelConfigurationRecord(
                id: existing.id,
                name: name,
                baseURL: nextBaseURL,
                apiKeyRef: existing.apiKeyRef,
                modelId: modelId,
                createdAt: existing.createdAt,
                kind: targetKind,
                supportsThinking: supportsThinking,
                maxContextTokens: maxContextTokens,
                isSelected: existing.isSelected,
                searchBackend: targetSearchBackend,
                providerId: providerId ?? existing.providerId
            )
            let committed = try await saveModelUpdate(updated, apiKey: apiKey, idGenerator: idGenerator)
            lastSavedModel = committed
            let wasDirectOpenAI = ProviderAudioCredential.isDirectOpenAI(
                providerId: existing.providerId, baseURL: existing.baseURL
            )
            let isDirectOpenAI = ProviderAudioCredential.isDirectOpenAI(
                providerId: committed.providerId, baseURL: committed.baseURL
            )
            // Narration borrows credentials, so metadata-only edits must not stop playback.
            if existing.apiKeyRef != committed.apiKeyRef || wasDirectOpenAI != isDirectOpenAI {
                await eventBus?.publish(.credentialChanged(id: id))
            }
            let resolvedKey: String?
            if !apiKey.isEmpty {
                resolvedKey = apiKey
            } else if let ref = committed.apiKeyRef {
                resolvedKey = try? await modelRepository.loadAPIKey(ref: ref)
            } else {
                resolvedKey = nil
            }
            // Build before unregistering so an unavailable replacement cannot remove the working provider.
            if let registry = llmProviderRegistry,
               let replacement = makeLLMProvider(
                   for: committed,
                   apiKey: resolvedKey,
                   http: httpClient,
                   toolRegistry: toolRegistry,
                   appleFoundationAvailability: appleFoundationAvailability
               ) {
                await registry.unregister(id: id)
                await registry.register(replacement)
            }
            await loadModels()
            onModelsChanged?()
            // Finish all committed-state publication before cleanup can suspend behind a newer edit.
            if let previousRef = existing.apiKeyRef, previousRef != committed.apiKeyRef {
                do {
                    try await modelRepository.discardStagedAPIKey(ref: previousRef)
                } catch {
                    chatSettingsLog.warning("Model saved, but its previous unused API key could not be removed from secure storage.")
                }
            }
            return committed
        } catch {
            chatSettingsLog.error("updateModel failed: \(String(describing: error), privacy: .public)")
            if error is ModelCredentialSaveError {
                publishModelEditError("Could not save model. Its existing API key is unchanged, but an unused replacement key could not be removed from secure storage. Restart the app to retry cleanup.", formSession: formSession)
            } else if case .staleModel = error as? ModelConfigurationRepositoryError {
                publishModelEditError("The model changed while saving. Reopen it and try again.", formSession: formSession)
            } else {
                publishModelEditError("Could not save model: \(error.localizedDescription)", formSession: formSession)
            }
            await loadModels()
            return nil
        }
    }

    private func saveModelUpdate(
        _ record: ModelConfigurationRecord, apiKey: String, idGenerator: any IDGenerator
    ) async throws -> ModelConfigurationRecord {
        guard !apiKey.isEmpty, let previousRef = record.apiKeyRef else {
            try await modelRepository.update(record, expectedAPIKeyRef: record.apiKeyRef)
            return record
        }
        // Stage under a fresh ref so concurrent readers only see the committed credential.
        // The row update publishes the replacement; an unsuccessful save never changes the old key.
        let stagedRef = idGenerator.nextID()
        var staged = record
        staged.apiKeyRef = stagedRef
        try await withStagedAPIKey(apiKey, ref: stagedRef) {
            try await modelRepository.update(staged, expectedAPIKeyRef: previousRef)
        }
        return staged
    }

    private func withStagedAPIKey(_ key: String, ref: String, commit: () async throws -> Void) async throws {
        try await modelRepository.registerStagedAPIKey(ref: ref)
        do {
            try await modelRepository.storeAPIKey(key, ref: ref)
            try await commit()
        } catch {
            do { try await modelRepository.discardStagedAPIKey(ref: ref) } catch {
                throw ModelCredentialSaveError.stagedKeyCleanupFailed
            }
            throw error
        }
    }

    private func publishModelEditError(_ message: String?, formSession: Int?) {
        if let formSession, !isModelFormSessionActive(formSession) { return }
        modelEditError = message
    }

    public func clearModelEditError() {
        modelEditError = nil
    }

    /// A form session scopes error publication; accepted deletion always finishes.
    /// Repository deletion removes the secret before its row.
    @discardableResult
    public func deleteModel(id: String, formSession: Int? = nil) async -> Bool {
        guard modelMutationIDs.insert(id).inserted else { return false }
        defer { modelMutationIDs.remove(id) }
        publishModelEditError(nil, formSession: formSession)
        if lastSavedModel?.id == id { lastSavedModel = nil }
        // An opaque deletion failure may follow successful Keychain removal. Discard the
        // live provider's cached secret before deletion, even if its row must remain for retry.
        await llmProviderRegistry?.unregister(id: id)
        var succeeded = true
        do {
            try await modelRepository.delete(id: id)
        } catch {
            publishModelEditError("Could not remove the model. Try again.", formSession: formSession)
            succeeded = false
        }
        onModelsChanged?()
        // A Keychain-first deletion can remove the key even if the following database write fails.
        await eventBus?.publish(.credentialChanged(id: id))
        await loadModels()
        return succeeded
    }

    /// Commits narration using this operation's returned row, independent of other model saves.
    @discardableResult
    public func commitAudioSetup(for row: ModelConfigurationRecord, enabled: Bool, useThisKey: Bool, revision: Int) async -> Bool {
        await commitAudioSetup(for: row, enabled: enabled, useThisKey: useThisKey, revision: revision, session: nil)
    }

    private func commitAudioSetup(
        for row: ModelConfigurationRecord, enabled: Bool, useThisKey: Bool, revision: Int, session: Int?
    ) async -> Bool {
        if let session, !isModelFormSessionActive(session) { return false }
        guard let audioSetup, let ref = row.apiKeyRef,
              ProviderAudioCredential.isDirectOpenAI(providerId: row.providerId, baseURL: row.baseURL) else { return true }
        do {
            try await audioSetup.commit(
                ProviderAudioCredential(id: row.id, name: row.name, keyRef: ref), enabled, useThisKey, revision
            )
            return session.map { isModelFormSessionActive($0) } ?? true
        } catch {
            if let session, !isModelFormSessionActive(session) { return false }
            modelEditError = "The model was saved, but narration settings were not. Review Narration settings and try again."
            return false
        }
    }

    /// Shared by reopened forms; mutation ownership lasts through publication and final key cleanup.
    public func isModelMutationInFlight(id: String) -> Bool { modelMutationIDs.contains(id) }

    /// Each appearance owns its completion actions independently of the model ID or navigation path.
    func beginModelFormSession() -> Int {
        navigationGeneration += 1
        modelFormGeneration += 1
        activeModelFormSession = modelFormGeneration
        return modelFormGeneration
    }

    func isModelFormSessionActive(_ session: Int) -> Bool { activeModelFormSession == session }

    func endModelFormSession(_ session: Int) {
        if activeModelFormSession == session { activeModelFormSession = nil }
    }

    @discardableResult
    func popModelForm(ifCurrent session: Int) -> Bool {
        guard isModelFormSessionActive(session) else { return false }
        endModelFormSession(session)
        popPane()
        return true
    }

    func commitModelFormAudioSetup(
        for row: ModelConfigurationRecord, enabled: Bool, useThisKey: Bool, revision: Int, session: Int
    ) async -> Bool {
        guard isModelFormSessionActive(session) else { return false }
        return await commitAudioSetup(for: row, enabled: enabled, useThisKey: useThisKey, revision: revision, session: session)
    }

    private func registerProvider(for record: ModelConfigurationRecord, apiKey: String?) async {
        guard let registry = llmProviderRegistry else { return }
        guard let provider = makeLLMProvider(
            for: record,
            apiKey: apiKey,
            http: httpClient,
            toolRegistry: toolRegistry,
            appleFoundationAvailability: appleFoundationAvailability
        ) else { return }
        await registry.register(provider)
    }

    public func model(id: String) -> ModelRow? {
        models.first { $0.id == id }
    }

    public func setToolEnabled(id: String, enabled: Bool) async {
        if let idx = tools.firstIndex(where: { $0.id == id }) {
            tools[idx].isEnabled = enabled
        }
        try? await toolRegistry.setEnabled(toolID: id, enabled: enabled)
    }

    /// Ignore blank text so a temporarily cleared editor cannot erase a saved memory.
    public func updateMemory(id: String, text: String, now: Date = Date()) async {
        guard let memoryRepository else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await memoryRepository.update(id: id, text: trimmed, updatedAt: now)
    }

    public func deleteMemory(id: String) async {
        guard let memoryRepository else { return }
        try? await memoryRepository.delete(id: id)
    }

    public func clearAllMemories() async {
        guard let memoryRepository else { return }
        try? await memoryRepository.clearAll()
    }

    /// Soft-delete active conversations, preserving their messages and tool calls.
    public func clearChatHistory(now: Date = Date()) async {
        let active = (try? await conversationRepository.listActive()) ?? []
        for row in active {
            try? await conversationRepository.softDelete(id: row.id, at: now)
        }
        await loadChatCount()
    }

    static func monogram(for name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let initials = parts.compactMap { $0.first.map(String.init) }
        return initials.prefix(2).joined()
    }

    static func shortEndpoint(_ url: URL) -> String {
        var raw = url.absoluteString
        if raw.hasPrefix("https://") { raw.removeFirst("https://".count) } else if raw.hasPrefix("http://") { raw.removeFirst("http://".count) }
        if raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }
}
