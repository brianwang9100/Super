import Core
import Foundation
import SwiftUI

/// View model backing `SettingsSheet`. Owns the resolved `ChatSettings`
/// snapshot, the configured-models list, the registered-tools list, and the
/// account chrome data shown in the root pane. Mutations write through to
/// the underlying repositories on the same call so the sheet is always in
/// sync with persistence.
///
/// SwiftUI re-renders via `@Observable`; the model itself is `@MainActor`
/// so all state changes are serialized without locks. The view model never
/// touches UI; `SettingsSheet` is a pure projection.
@MainActor
@Observable
public final class SettingsViewModel {
    /// One row in the Models pane. Carries enough of the underlying
    /// record for the detail pane to seed its form without re-fetching —
    /// the trailing init args have defaults so test fixtures that only
    /// care about the visible chrome (id/name/monogram/endpoint) still
    /// compile.
    public struct ModelRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let monogram: String
        public let endpoint: String
        public let maxContextTokens: Int
        public var isEnabled: Bool
        public let baseURL: URL
        public let modelId: String
        public let supportsThinking: Bool

        public init(
            id: String,
            name: String,
            monogram: String,
            endpoint: String,
            maxContextTokens: Int,
            isEnabled: Bool,
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            modelId: String = "",
            supportsThinking: Bool = false
        ) {
            self.id = id
            self.name = name
            self.monogram = monogram
            self.endpoint = endpoint
            self.maxContextTokens = maxContextTokens
            self.isEnabled = isEnabled
            self.baseURL = baseURL
            self.modelId = modelId
            self.supportsThinking = supportsThinking
        }
    }

    /// One row in the Tools pane.
    public struct ToolRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let summary: String
        public var isEnabled: Bool

        public init(id: String, name: String, summary: String, isEnabled: Bool) {
            self.id = id
            self.name = name
            self.summary = summary
            self.isEnabled = isEnabled
        }
    }

    /// Persisted, typed snapshot of every Chat preference.
    public private(set) var settings: ChatSettings = .default

    /// Models registered in `ModelConfigurationRepository`.
    public private(set) var models: [ModelRow] = []

    /// Tools registered in the live `ToolRegistry`.
    public private(set) var tools: [ToolRow] = []

    /// Number of non-deleted conversations. Surfaced as the trailing value
    /// on the Data row in the root pane.
    public private(set) var chatCount: Int = 0

    /// Stack of pushed sub-panes. Empty means the root is showing.
    /// Bound to `SettingsSheet`'s `NavigationStack(path:)`, which is what
    /// produces the native push/pop slide animation. Public so external
    /// callers (e.g. a chat-side affordance) can deep-link into a pane:
    /// `viewModel.openPane(.modelDetail(id: nil))`.
    public var navigationPath: [SettingsSheet.Pane] = []

    /// Account email shown in the chip at the top of the root pane.
    /// Hardcoded to the user identity for MVP.
    public let accountEmail: String

    /// Bundle metadata surfaced in the About pane and the root pane row.
    /// Injected so snapshot tests get a stable string instead of the host
    /// bundle's actual version.
    public let appInfo: SuperAppInfo

    private let store: ChatSettingsStore
    private let modelRepository: any ModelConfigurationRepository
    private let conversationRepository: any ConversationRepository
    private let toolRegistry: ToolRegistry
    private let llmProviderRegistry: LLMProviderRegistry?
    private let httpClient: (any HTTPClient)?

    /// Optional notification fired after the models list changes via
    /// `createModel`/`updateModel`/`deleteModel`. The host wires this so
    /// the chat surface picks up newly added providers without an app
    /// restart (e.g. refreshing `ChatScreenViewModel.availableModels`).
    public var onModelsChanged: (@MainActor () -> Void)?

    public init(
        accountEmail: String,
        appInfo: SuperAppInfo,
        settingRepository: any SettingRepository,
        modelRepository: any ModelConfigurationRepository,
        conversationRepository: any ConversationRepository,
        toolRegistry: ToolRegistry,
        llmProviderRegistry: LLMProviderRegistry? = nil,
        httpClient: (any HTTPClient)? = nil
    ) {
        self.accountEmail = accountEmail
        self.appInfo = appInfo
        self.store = ChatSettingsStore(repository: settingRepository)
        self.modelRepository = modelRepository
        self.conversationRepository = conversationRepository
        self.toolRegistry = toolRegistry
        self.llmProviderRegistry = llmProviderRegistry
        self.httpClient = httpClient
    }

    /// `true` once `load()` has populated state from any source — the
    /// snapshot seam below also flips it so the sheet's `.task` doesn't
    /// race a real `load()` against pre-baked test state.
    private var hasLoaded: Bool = false

    /// Pre-populate state synchronously for snapshot tests + previews so the
    /// sheet renders without a repository round-trip. Production callers
    /// should always go through `load()`. Setting `hasLoaded = true` here
    /// is what makes the snapshot harness deterministic — without it the
    /// sheet's `.task` would fire `load()` against the harness's noop
    /// repos and clobber the seeded data mid-render.
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

    /// Re-read every datasource. Called from the sheet's `.task` so the
    /// first present always shows live state. Errors are swallowed so the
    /// sheet still renders with whatever loaded successfully.
    ///
    /// Idempotent — repeat calls after the first successful load skip the
    /// repo round-trip. The four reads run in parallel so opening the
    /// sheet pays the slowest (not the sum) of them.
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
            rows.append(ModelRow(
                id: record.id,
                name: record.name,
                monogram: Self.monogram(for: record.name),
                endpoint: Self.shortEndpoint(record.baseURL),
                maxContextTokens: record.maxContextTokens,
                isEnabled: stored ?? true,
                baseURL: record.baseURL,
                modelId: record.modelId,
                supportsThinking: record.supportsThinking
            ))
        }
        models = rows
    }

    private func loadTools() async {
        let registrations = await toolRegistry.allRegistrations()
        tools = registrations.map { reg in
            ToolRow(
                id: reg.tool.id,
                name: reg.tool.name,
                summary: reg.tool.description,
                isEnabled: reg.isEnabled
            )
        }
    }

    private func loadChatCount() async {
        let rows = (try? await conversationRepository.listActive()) ?? []
        chatCount = rows.count
    }

    // MARK: - Mutations

    public func setTheme(_ id: ChatSettings.ThemeID) async {
        settings.themeId = id
        try? await store.setTheme(id)
    }

    public func setSystemPrompt(_ value: String) async {
        settings.systemPrompt = value
        try? await store.setSystemPrompt(value)
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

    public func setDensity(_ value: ChatSettings.Density) async {
        settings.density = value
        try? await store.setDensity(value)
    }

    public func setAutoCompactEnabled(_ value: Bool) async {
        settings.autoCompactEnabled = value
        try? await store.setAutoCompactEnabled(value)
    }

    public func setAutoCompactThreshold(_ value: Double) async {
        let clamped = ChatSettings.clampThreshold(value)
        settings.autoCompactThreshold = clamped
        try? await store.setAutoCompactThreshold(clamped)
    }

    public func setModelEnabled(id: String, enabled: Bool) async {
        if let idx = models.firstIndex(where: { $0.id == id }) {
            models[idx].isEnabled = enabled
        }
        try? await store.setModelEnabled(id: id, enabled: enabled)
    }

    // MARK: - Navigation

    /// Push a pane onto the stack. The bound `NavigationStack` animates
    /// the transition. Safe to call from anywhere on the main actor; this
    /// is the entry point for both in-sheet row taps and external
    /// deep-links (e.g. opening Settings preconfigured to model detail).
    public func openPane(_ pane: SettingsSheet.Pane) {
        guard pane != .root else {
            navigationPath.removeAll()
            return
        }
        navigationPath.append(pane)
    }

    /// Pop one pane off the stack. No-op when already at root.
    ///
    /// If a pane has installed `beforePopCleanup`, the closure runs first
    /// (it's the active pane's hook to scrub draft state — e.g. the model
    /// detail pane clearing its `SecureField` so iOS doesn't queue a
    /// "Save Password?" prompt on the dismissed view). The cleanup
    /// happens *before* the path mutation and we yield one main-actor
    /// tick so SwiftUI flushes the @State change into UIKit before the
    /// view is torn down.
    public func popPane() {
        if let cleanup = beforePopCleanup {
            beforePopCleanup = nil
            cleanup()
            Task { @MainActor in
                await Task.yield()
                guard !navigationPath.isEmpty else { return }
                navigationPath.removeLast()
            }
        } else {
            guard !navigationPath.isEmpty else { return }
            navigationPath.removeLast()
        }
    }

    /// Clear the entire stack (back to root). Called by the sheet on
    /// dismiss so re-presenting always starts at root. Runs the active
    /// pane's cleanup first for the same reason as `popPane()`.
    public func popToRoot() {
        if let cleanup = beforePopCleanup {
            beforePopCleanup = nil
            cleanup()
        }
        navigationPath.removeAll()
    }

    /// Optional hook the active pane installs in `onAppear` and tears
    /// down in `onDisappear`. `popPane()` and `popToRoot()` invoke it
    /// once before the path mutation so panes can scrub sensitive draft
    /// state (e.g. typed-but-not-saved API keys) ahead of the view's
    /// dismissal — preventing iOS from queueing a save-password prompt
    /// on the discarded content.
    public var beforePopCleanup: (@MainActor () -> Void)?

    // MARK: - Model CRUD

    /// Insert a brand-new model row. Stores the API key under a freshly
    /// generated Keychain ref, then writes the record. The generated ids
    /// (record + key ref) are injectable so tests can pin them.
    /// Also registers a matching `LLMProvider` with the registry (when
    /// injected) so the chat surface can use the new model immediately —
    /// without it the user would have to relaunch the app.
    public func createModel(
        name: String,
        baseURL: URL,
        modelId: String,
        apiKey: String,
        supportsThinking: Bool,
        maxContextTokens: Int,
        idGenerator: () -> String = { UUID().uuidString },
        now: Date = Date()
    ) async {
        let ref = idGenerator()
        let recordId = idGenerator()
        do {
            try await modelRepository.storeAPIKey(apiKey, ref: ref)
            let record = ModelConfigurationRecord(
                id: recordId,
                name: name,
                baseURL: baseURL,
                apiKeyRef: ref,
                modelId: modelId,
                supportsThinking: supportsThinking,
                maxContextTokens: maxContextTokens,
                isSelected: false,
                createdAt: now
            )
            try await modelRepository.save(record)
            await registerProvider(for: record, apiKey: apiKey)
            await loadModels()
            onModelsChanged?()
        } catch {
            // Keep models list in sync with what actually persisted; a
            // failed save just means the row never appears.
            await loadModels()
        }
    }

    /// Update an existing row. A blank `apiKey` argument leaves the
    /// stored key untouched — the form treats the field as "tap to
    /// change" and only writes through when the user types something.
    /// Re-registers the provider so the live chat surface picks up the
    /// new endpoint/model id without an app restart.
    public func updateModel(
        id: String,
        name: String,
        baseURL: URL,
        modelId: String,
        apiKey: String,
        supportsThinking: Bool,
        maxContextTokens: Int
    ) async {
        guard let existing = try? await modelRepository.fetch(id: id) else { return }
        if !apiKey.isEmpty {
            try? await modelRepository.storeAPIKey(apiKey, ref: existing.apiKeyRef)
        }
        let updated = ModelConfigurationRecord(
            id: existing.id,
            name: name,
            baseURL: baseURL,
            apiKeyRef: existing.apiKeyRef,
            modelId: modelId,
            supportsThinking: supportsThinking,
            maxContextTokens: maxContextTokens,
            isSelected: existing.isSelected,
            createdAt: existing.createdAt
        )
        try? await modelRepository.save(updated)
        let resolvedKey = apiKey.isEmpty
            ? (try? await modelRepository.loadAPIKey(ref: existing.apiKeyRef))
            : apiKey
        await llmProviderRegistry?.unregister(id: id)
        await registerProvider(for: updated, apiKey: resolvedKey ?? nil)
        await loadModels()
        onModelsChanged?()
    }

    /// Delete a row + its Keychain entry. The repository handles the
    /// Keychain-first ordering so a failed delete leaves the row in place
    /// rather than orphaning a secret. Also unregisters the provider so
    /// the deleted endpoint disappears from the picker right away.
    public func deleteModel(id: String) async {
        try? await modelRepository.delete(id: id)
        await llmProviderRegistry?.unregister(id: id)
        await loadModels()
        onModelsChanged?()
    }

    /// Build a fresh `OpenAICompatibleLLMProvider` for `record` and
    /// register it with the live registry. No-op when no registry/HTTP
    /// client was injected (tests and previews don't wire them).
    private func registerProvider(for record: ModelConfigurationRecord, apiKey: String?) async {
        guard let registry = llmProviderRegistry, let http = httpClient else { return }
        let provider = OpenAICompatibleLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
        await registry.register(provider)
    }

    /// Look up a row by id without re-fetching. The detail pane uses this
    /// to seed its form — it's safe to read straight off the in-memory
    /// snapshot because the pane is only reachable via the root pane,
    /// which always loads first.
    public func model(id: String) -> ModelRow? {
        models.first { $0.id == id }
    }

    public func setToolEnabled(id: String, enabled: Bool) async {
        if let idx = tools.firstIndex(where: { $0.id == id }) {
            tools[idx].isEnabled = enabled
        }
        try? await toolRegistry.setEnabled(toolID: id, enabled: enabled)
    }

    /// Soft-delete every active conversation. Cascades through the schema
    /// so messages + tool calls go with them. Refreshes `chatCount` after.
    public func clearChatHistory(now: Date = Date()) async {
        let active = (try? await conversationRepository.listActive()) ?? []
        for row in active {
            try? await conversationRepository.softDelete(id: row.id, at: now)
        }
        await loadChatCount()
    }

    // MARK: - Helpers

    /// First letter of each space-separated word (max 2). Mirrors the
    /// monogram tile in `settings.jsx`'s `ModelsPane`.
    static func monogram(for name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let initials = parts.compactMap { $0.first.map(String.init) }
        return initials.prefix(2).joined()
    }

    /// Strip `https://` and trailing `/` so the endpoint fits the cramped
    /// metadata line under the model name.
    static func shortEndpoint(_ url: URL) -> String {
        var raw = url.absoluteString
        if raw.hasPrefix("https://") { raw.removeFirst("https://".count) }
        else if raw.hasPrefix("http://") { raw.removeFirst("http://".count) }
        if raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }
}
