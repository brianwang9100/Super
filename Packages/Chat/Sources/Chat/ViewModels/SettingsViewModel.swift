import Core
import Foundation
import os
import SwiftUI

/// Production diagnostics for the Settings pane's model-CRUD path. Lives
/// at file scope (not on the view model) so static methods and tests
/// observe the same Logger instance. Category `chat-settings` so future
/// settings-side telemetry can join under one filter.
private let chatSettingsLog = Logger(subsystem: "com.brianwang.Super", category: "chat-settings")

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
        /// `true` when a Keychain entry exists for this row's `apiKeyRef`.
        /// Resolved once in `loadModels()` so `SettingsModelDetailPane`
        /// can pre-fill the API-key `SecureField` with placeholder bullets
        /// synchronously at init time (the alternative — an async check
        /// in `.task` — would flicker an empty field on first frame and
        /// leave snapshot tests racing the load).
        public let hasAPIKey: Bool

        public init(
            id: String,
            name: String,
            monogram: String,
            endpoint: String,
            maxContextTokens: Int,
            isEnabled: Bool,
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            modelId: String = "",
            supportsThinking: Bool = false,
            hasAPIKey: Bool = false
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
            self.hasAPIKey = hasAPIKey
        }
    }

    /// One row in the Tools pane.
    public struct ToolRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let summary: String
        public var isEnabled: Bool
        /// Settings pane reached by tapping the gear affordance on this
        /// row, or `nil` when the tool has no configuration UI. The row
        /// renders the gear only when both this is non-nil *and*
        /// `isEnabled` is true — there's no point configuring an off
        /// tool.
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

    /// Persisted, typed snapshot of every Chat preference.
    public private(set) var settings: ChatSettings = .default

    /// Models registered in `ModelConfigurationRepository`.
    public private(set) var models: [ModelRow] = []

    /// Tools registered in the live `ToolRegistry`.
    public private(set) var tools: [ToolRow] = []

    /// Number of non-deleted conversations. Surfaced as the trailing value
    /// on the Data row in the root pane.
    public private(set) var chatCount: Int = 0

    /// User-facing error message from the most recent `createModel` /
    /// `updateModel` attempt, or `nil` when the last attempt succeeded or
    /// none has been made. The model-detail pane reads this to render an
    /// inline error under the Save button — without it, a Keychain or
    /// repository failure produces a silent dismiss and the user is left
    /// wondering why no row appeared.
    public private(set) var modelEditError: String?

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
    /// Persistence boundary for the memory pane's mutations. Optional so
    /// snapshot tests and previews can construct the VM without standing
    /// up a memory store; the production composition root wires the
    /// real `GRDBMemoryRepository`.
    private let memoryRepository: (any MemoryRepository)?
    private let llmProviderRegistry: LLMProviderRegistry?
    private let httpClient: (any HTTPClient)?
    /// Receiver that runtime-pushes user-personalization edits into
    /// orchestration (production: `ChatSessionStore`). Protocol-typed
    /// per AGENTS.md §Testing §1 so tests can verify the fan-out hop
    /// without the full orchestration graph. Required, not optional — a
    /// `nil` default would make a wiring regression in the composition
    /// root invisible (the persisted value would diverge from running
    /// sessions with no compile error or runtime signal). Tests
    /// substitute a no-op receiver.
    private let userPersonalizationReceiver: any UserPersonalizationReceiver

    /// Receiver that runtime-pushes auto-compaction toggle/threshold
    /// edits into orchestration (production: `ChatSessionStore`). Same
    /// required-non-optional rationale as `userPersonalizationReceiver`
    /// — a silently-dropped slider would leave the persisted value
    /// diverged from running sessions until the next app launch.
    private let autoCompactPolicyReceiver: any AutoCompactPolicyReceiver

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
        userPersonalizationReceiver: any UserPersonalizationReceiver,
        autoCompactPolicyReceiver: any AutoCompactPolicyReceiver,
        memoryRepository: (any MemoryRepository)? = nil,
        llmProviderRegistry: LLMProviderRegistry? = nil,
        httpClient: (any HTTPClient)? = nil
    ) {
        self.accountEmail = accountEmail
        self.appInfo = appInfo
        self.store = ChatSettingsStore(repository: settingRepository)
        self.modelRepository = modelRepository
        self.conversationRepository = conversationRepository
        self.toolRegistry = toolRegistry
        self.memoryRepository = memoryRepository
        self.llmProviderRegistry = llmProviderRegistry
        self.userPersonalizationReceiver = userPersonalizationReceiver
        self.autoCompactPolicyReceiver = autoCompactPolicyReceiver
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
            let keyExists = (try? await modelRepository.loadAPIKey(ref: record.apiKeyRef)).flatMap { $0 } != nil
            rows.append(ModelRow(
                id: record.id,
                name: record.name,
                monogram: Self.monogram(for: record.name),
                endpoint: Self.shortEndpoint(record.baseURL),
                maxContextTokens: record.maxContextTokens,
                isEnabled: stored ?? true,
                baseURL: record.baseURL,
                modelId: record.modelId,
                supportsThinking: record.supportsThinking,
                hasAPIKey: keyExists
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
                isEnabled: reg.isEnabled,
                configPane: Self.configPane(forToolID: reg.tool.id)
            )
        }
    }

    /// Tool-id → settings pane mapping for the "gear" affordance on
    /// `SettingsToolsPane`. New configurable tools register their pane
    /// here; everything else returns nil (no gear shown). Kept as a
    /// table inside the view model rather than data on `ToolRegistration`
    /// because pane identity is a UI concern, not a Core protocol
    /// concern.
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

    // MARK: - Mutations

    public func setTheme(_ id: ChatSettings.ThemeID) async {
        settings.themeId = id
        try? await store.setTheme(id)
    }

    public func setUserPersonalization(_ value: String) async {
        settings.userPersonalization = value
        try? await store.setUserPersonalization(value)
        // Fan out to every active `ChatSession` (via the receiver, which
        // is `ChatSessionStore` in production) so long-running
        // conversations pick up the new value on their next turn — the
        // Personalization pane's "save on focus loss" hand-off would
        // otherwise need the user to restart the app to take effect.
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
        // Fan out to every active `ChatSession` so a long-running
        // conversation picks up the new toggle on its next turn —
        // otherwise the persisted value would diverge from running
        // sessions until the user restarted the app.
        await autoCompactPolicyReceiver.setAutoCompactPolicy(
            enabled: settings.autoCompactEnabled,
            threshold: settings.autoCompactThreshold
        )
    }

    public func setAutoCompactThreshold(_ value: Double) async {
        let clamped = ChatSettings.clampThreshold(value)
        settings.autoCompactThreshold = clamped
        try? await store.setAutoCompactThreshold(clamped)
        // Same runtime-propagation rationale as `setAutoCompactEnabled`.
        await autoCompactPolicyReceiver.setAutoCompactPolicy(
            enabled: settings.autoCompactEnabled,
            threshold: settings.autoCompactThreshold
        )
    }

    public func setModelEnabled(id: String, enabled: Bool) async {
        if let idx = models.firstIndex(where: { $0.id == id }) {
            models[idx].isEnabled = enabled
        }
        try? await store.setModelEnabled(id: id, enabled: enabled)
    }

    /// Remembers the model the user just activated so the next new chat
    /// opens on it. Called by the host from `ChatScreenViewModel`'s
    /// `onModelSelected` hook (user picks in the composer) and from the
    /// initial auto-pick path in `ContentView.rebuildChatViewModel`.
    public func setLastSelectedModelId(_ id: String) async {
        settings.lastSelectedModelId = id
        try? await store.setLastSelectedModelId(id)
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
    ///
    /// On failure, sets ``modelEditError`` to a human-readable string and
    /// logs the underlying error via the unified log. Callers
    /// (`SettingsModelDetailPane`) read ``modelEditError`` to decide
    /// whether to pop the pane (nil → success, pop; non-nil → keep the
    /// pane up so the user sees the error). Re-trying clears the error
    /// at the start of the next attempt.
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
        modelEditError = nil
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
            chatSettingsLog.error("createModel failed: \(String(describing: error), privacy: .public)")
            modelEditError = "Could not save model: \(error.localizedDescription)"
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
    ///
    /// Same error-surface contract as `createModel(...)`: on failure
    /// sets ``modelEditError`` and the pane stays open so the user can
    /// retry. On success ``modelEditError`` is nil.
    public func updateModel(
        id: String,
        name: String,
        baseURL: URL,
        modelId: String,
        apiKey: String,
        supportsThinking: Bool,
        maxContextTokens: Int
    ) async {
        modelEditError = nil
        do {
            guard let existing = try await modelRepository.fetch(id: id) else {
                modelEditError = "Could not save model: row no longer exists."
                return
            }
            if !apiKey.isEmpty {
                try await modelRepository.storeAPIKey(apiKey, ref: existing.apiKeyRef)
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
            try await modelRepository.save(updated)
            let resolvedKey = apiKey.isEmpty
                ? (try? await modelRepository.loadAPIKey(ref: existing.apiKeyRef))
                : apiKey
            await llmProviderRegistry?.unregister(id: id)
            await registerProvider(for: updated, apiKey: resolvedKey)
            await loadModels()
            onModelsChanged?()
        } catch {
            chatSettingsLog.error("updateModel failed: \(String(describing: error), privacy: .public)")
            modelEditError = "Could not save model: \(error.localizedDescription)"
            await loadModels()
        }
    }

    /// Reset the model-edit error. Called by `SettingsModelDetailPane`
    /// on appear so a stale message from a previous attempt doesn't
    /// flash on the next open.
    public func clearModelEditError() {
        modelEditError = nil
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

    // MARK: - Memory mutations

    /// Rewrite a memory's text. The reactive `@Query` in
    /// `SettingsMemoryPane` picks up the change automatically; the
    /// orchestrator's next `assemble(...)` sees the new value.
    /// Empty / whitespace-only text is silently ignored — the pane
    /// commits on focus loss, so a momentarily-cleared editor would
    /// otherwise wipe the row.
    ///
    /// `now` is an injection seam (matching `clearChatHistory(now:)`)
    /// so tests can assert the exact `updatedAt` written without
    /// reaching for the wall clock — per AGENTS.md §Testing rule 1.
    public func updateMemory(id: String, text: String, now: Date = Date()) async {
        guard let memoryRepository else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await memoryRepository.update(id: id, text: trimmed, updatedAt: now)
    }

    /// Drop one memory.
    public func deleteMemory(id: String) async {
        guard let memoryRepository else { return }
        try? await memoryRepository.delete(id: id)
    }

    /// Wipe every memory. Called by the pane's "Clear All" affordance
    /// after the user confirms.
    public func clearAllMemories() async {
        guard let memoryRepository else { return }
        try? await memoryRepository.clearAll()
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
        if raw.hasPrefix("https://") { raw.removeFirst("https://".count) } else if raw.hasPrefix("http://") { raw.removeFirst("http://".count) }
        if raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }
}
