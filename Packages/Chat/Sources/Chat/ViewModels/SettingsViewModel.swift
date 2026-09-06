import Core
import Foundation
import FoundationModels
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
        public let kind: LLMProviderKind
        public let name: String
        public let monogram: String
        public let endpoint: String
        public let maxContextTokens: Int
        public var isEnabled: Bool
        /// Nil for on-device kinds (`.appleFoundation`). Present for any
        /// `.openAICompatible` row that reached this view model.
        public let baseURL: URL?
        public let modelId: String
        public let supportsThinking: Bool
        /// `true` when a Keychain entry exists for this row's `apiKeyRef`.
        /// Resolved once in `loadModels()` so `SettingsModelDetailPane`
        /// can pre-fill the API-key `SecureField` with placeholder bullets
        /// synchronously at init time (the alternative — an async check
        /// in `.task` — would flicker an empty field on first frame and
        /// leave snapshot tests racing the load). Always `false` for
        /// `.appleFoundation` rows since they carry no key.
        public let hasAPIKey: Bool
        /// Selected web-search engine for this row (mirrors
        /// `ModelConfigurationRecord.searchBackend`): `"native"`, a
        /// standalone search-provider id, or `nil`. Surfaced here so the
        /// Add-Model native-search UI (next PR) reads it off the loaded row
        /// instead of re-fetching the record — without this projection the
        /// field would silently read `nil` and the toggle would show "off"
        /// for a row that actually has search configured.
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

    /// In-memory, session-scoped cache of live "list models" results, keyed
    /// by Add-Model provider id (e.g. `"openai"`). Populated by `loadModels`;
    /// `SettingsModelDetailPane` reads it to drive the Model dropdown, falling
    /// back to the static `LLMProviderCatalog` when a provider has no entry.
    /// Deliberately not persisted — a fresh launch re-fetches on demand (the
    /// user asked for an in-memory cache, not a stored one).
    public private(set) var fetchedModels: [String: [LLMCatalogModel]] = [:]

    /// Provider id whose model list is currently being fetched, or `nil` when
    /// no fetch is in flight. The detail pane swaps the refresh affordance for
    /// a spinner while this matches the visible provider.
    public private(set) var loadingModelsProviderID: String?

    /// Per-provider note shown under the Model dropdown when the live list
    /// couldn't load (no/bad key, offline, missing endpoint) and the catalog
    /// fallback is showing instead. Keyed by provider id; cleared on a
    /// successful fetch.
    public private(set) var modelListNote: [String: String] = [:]

    /// Per-provider fetch generation. Bumped when a fetch passes the
    /// guards and starts; a completion whose generation is no longer
    /// current discards its writes. Two same-provider fetches can be in
    /// flight at once — the edit pane's stored-key fetch on appear and
    /// the typed-key debounce — and without this, a slow stale fetch
    /// (e.g. a revoked stored key timing out into a 401) would clobber
    /// the fresh list with the fallback note. Last-STARTED wins.
    private var modelListFetchGeneration: [String: Int] = [:]

    /// Stack of pushed sub-panes. Empty means the root pane is showing.
    /// Bound to `SettingsSheet`'s `NavigationStack(path:)`, which is what
    /// produces the native push/pop slide animation. Public so external
    /// callers (e.g. a chat-side affordance) can deep-link into a pane:
    /// `viewModel.openPane(.modelDetail(id: nil))`.
    public var navigationPath: [SettingsSheet.Pane] = []

    /// The pane shown at the base of the navigation stack. `.root` for the
    /// normal Settings entry; a deep-linked pane (e.g. `.models` from the
    /// composer's "Manage models…") presented as its own modal root. The
    /// leading header button is a close-✕ at this base pane and a back chevron
    /// once `navigationPath` pushes deeper. The host sets this on every open,
    /// so it can't go stale across presentations.
    public var rootPane: SettingsSheet.Pane = .root

    /// Bundle metadata surfaced in the About pane and the root pane row.
    /// Injected so snapshot tests get a stable string instead of the host
    /// bundle's actual version.
    public let appInfo: SuperAppInfo

    public let audioSetup: ProviderAudioSetup?
    private let eventBus: SuperEventBus?
    public private(set) var lastSavedModel: ModelConfigurationRecord?
    private let store: ChatSettingsStore
    private let modelRepository: any ModelConfigurationRepository
    private let conversationRepository: any ConversationRepository
    private let toolRegistry: ToolRegistry

    /// Drives the Data pane's "Export all chats" job (background export →
    /// download/share). Constructed in `init` from the repositories; the Data
    /// pane reads `exportController.phase` and calls `start()`/`cancel()`.
    public let exportController: ChatExportController
    /// Persistence boundary for the memory pane's mutations. Optional so
    /// snapshot tests and previews can construct the VM without standing
    /// up a memory store; the production composition root wires the
    /// real `GRDBMemoryRepository`.
    private let memoryRepository: (any MemoryRepository)?
    private let llmProviderRegistry: LLMProviderRegistry?
    private let httpClient: (any HTTPClient)?
    /// Issues the live `GET …/models` call behind `loadModels`. Resolved in
    /// `init` to a `LiveModelListingService` over the injected `httpClient`
    /// when not supplied directly; `nil` only when there's no HTTP client
    /// (snapshot/preview fixtures), in which case `loadModels` no-ops and the
    /// dropdown stays on the catalog. Tests inject a strict fake.
    private let modelListingService: (any ModelListingService)?
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

    /// Receiver that runtime-pushes the web-search cost-gate toggle into
    /// orchestration (production: `ChatSessionStore`). Same required-non-
    /// optional rationale as `autoCompactPolicyReceiver` — a silently-
    /// dropped toggle would leave the persisted value diverged from
    /// running sessions until the next app launch.
    private let webSearchPolicyReceiver: any WebSearchPolicyReceiver

    /// Shared app-wide haptics engine. The Settings toggle mutes/unmutes it
    /// live via `setEnabled(_:)`. Defaults to a no-op so snapshot/preview
    /// fixtures construct the VM without the real engine.
    private let hapticsEngine: any HapticsEngine

    /// Optional notification fired after the models list changes via
    /// `createModel`/`updateModel`/`deleteModel`. The host wires this so
    /// the chat surface picks up newly added providers without an app
    /// restart (e.g. refreshing `ChatScreenViewModel.availableModels`).
    public var onModelsChanged: (@MainActor () -> Void)?

    /// Live AFM availability surfaced to the panes so an
    /// `.appleFoundation` row can render its subtitle and toggle state
    /// from the OS rather than from the persisted record alone.
    ///
    /// Snapshotted once at init from `SystemLanguageModel.default.availability`
    /// (or the injected override in tests). The Apple SDK marks the
    /// underlying property as `Observable`, so a future revision could
    /// re-read on every render; for the MVP a launch-time snapshot is
    /// fine — toggling Apple Intelligence in System Settings already
    /// requires an app relaunch to take effect.
    public let appleFoundationAvailability: AppleFoundationAvailability

    /// The on-device AFM context window surfaced to the panes so the
    /// `.appleFoundation` detail row can render (read-only) and persist the
    /// real window. Snapshotted once at init from
    /// `AppleFoundationLLMProvider.deviceContextTokens` (or the injected
    /// override in tests/fixtures, which keeps snapshots deterministic without
    /// touching the real device API).
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
        // Optional (mirrors `memoryRepository`) so snapshot/preview fixtures
        // construct the VM without standing up the full repository graph;
        // production wires both. When either is nil the export controller gets
        // an inert exporter — fixtures drive its phase via the snapshot seam.
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
        // Default the listing service to a live one over the injected HTTP
        // client so neither app bootstrap has to wire it explicitly; fixtures
        // that pass neither get a nil service and `loadModels` no-ops.
        self.modelListingService = modelListingService ?? httpClient.map { LiveModelListingService(http: $0) }
        self.appleFoundationAvailability = appleFoundationAvailability
        self.appleFoundationContextTokens = appleFoundationContextTokens
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

    /// Snapshot seam for the live model-list states the Add-Model dropdown
    /// renders (loaded list / in-flight spinner / fallback note) without a
    /// real fetch. Underscore-prefixed: test-only surface, not stable API.
    func _setModelListSnapshotState(
        fetchedModels: [String: [LLMCatalogModel]] = [:],
        loadingModelsProviderID: String? = nil,
        modelListNote: [String: String] = [:]
    ) {
        self.fetchedModels = fetchedModels
        self.loadingModelsProviderID = loadingModelsProviderID
        self.modelListNote = modelListNote
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

    /// Fetch the live "list models" result for `providerID` into
    /// `fetchedModels`, the in-memory source the Add-Model "Model" dropdown
    /// reads. Distinct from the private `loadModels()` above, which loads the
    /// user's *configured* model rows.
    ///
    /// Behavior (matches the chosen UX — auto-fetch on provider select, manual
    /// refresh icon, catalog fallback on failure):
    /// - **Cache hit + `!force`** → returns immediately; the session cache is
    ///   authoritative until the user taps refresh.
    /// - **Empty/whitespace key** → no network call. Built-in listing needs a
    ///   key; the dropdown stays on the catalog fallback until one is entered
    ///   (the pane's debounced key-typed fetch and the refresh icon are the
    ///   post-key fetch paths).
    /// - **Cancellation** → no state change; the pane's debounce cancels the
    ///   in-flight fetch on every keystroke and the restarted fetch owns the
    ///   next state.
    /// - **No catalog entry / no base URL** (Apple, Custom) → no-op; those
    ///   providers don't list.
    /// - **Success** → store the reconciled list and clear any note.
    /// - **Empty result / failure** → clear any stale cache entry and record
    ///   the fallback note. Clearing matters on a *forced* refresh after an
    ///   earlier success: without it the dropdown would keep showing the old
    ///   live list while the note claims "showing built-in list" — so the
    ///   cache is dropped to make the catalog fallback (and the note) honest.
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
        // Guard the reset so a concurrent fetch for a *different* provider
        // can't clear this one's spinner (and vice versa). Two forced fetches
        // for the *same* provider still share the flag — the first to finish
        // clears it — but that's a benign quick-double-tap edge; the cache
        // writes are generation-guarded below.
        defer { if loadingModelsProviderID == providerID { loadingModelsProviderID = nil } }
        do {
            let ids = try await service.listModelIDs(kind: entry.kind, baseURL: baseURL, apiKey: key)
            // A newer fetch for this provider started while this one was on
            // the wire (the edit pane's stored-key appear-fetch racing the
            // typed-key debounce). Its result owns the state; discard ours.
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
            // A *cancelled* fetch is not a failure: the pane's debounced
            // `.task(id: apiKey)` cancels the in-flight request on every
            // keystroke, and wiping the cache + posting the fallback note
            // here would flash a false error mid-typing (the service wraps
            // `CancellationError` into `.transport`, so check the task, not
            // the error type). The restarted fetch owns the next state.
            guard !Task.isCancelled else { return }
            // Same staleness rule as the success path: a superseded
            // fetch's failure must not wipe the newer fetch's list.
            guard modelListFetchGeneration[providerID] == generation else { return }
            fetchedModels[providerID] = nil
            modelListNote[providerID] = Self.modelListFallbackNote
        }
    }

    /// Edit-mode companion to ``loadAvailableModels(providerID:apiKey:force:)``:
    /// resolves the editing row's stored Keychain key (via its `apiKeyRef`)
    /// and delegates. The detail pane calls this when the key field still
    /// holds the synthetic placeholder bullets — i.e. the user hasn't typed
    /// a new key, so the stored one is the only real credential available.
    ///
    /// When the row, ref, or stored key is missing: a passive (appear-time,
    /// `force: false`) fetch is a silent no-op — mirroring create mode's
    /// empty-key gate, where an absent key means "can't list yet", not
    /// "listing failed". A *forced* fetch (the user explicitly tapped the
    /// refresh icon) posts the fallback note instead, so the affordance
    /// isn't a dead button when the Keychain entry is gone. A fetch
    /// failure with a resolved key posts the note via the delegate.
    public func loadAvailableModelsUsingStoredKey(
        providerID: String,
        editingModelID: String,
        force: Bool
    ) async {
        guard modelListingService != nil else { return }
        // Cache-hit short-circuit BEFORE the repo/Keychain round-trip —
        // the delegate would skip the fetch anyway, but only after we
        // paid for two async reads.
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

    /// Inline note shown under the Model dropdown when the live list can't load
    /// and the curated catalog is showing instead.
    static let modelListFallbackNote = "Couldn't load live models — showing built-in list."

    private func loadTools() async {
        let registrations = await toolRegistry.allRegistrations()
        tools = registrations.map { reg in
            ToolRow(
                id: reg.tool.id,
                // User-facing label, never the LLM-facing `description`. Fall
                // back to the technical `name` when a tool ships no friendly
                // copy.
                name: reg.tool.displayName ?? reg.tool.name,
                summary: reg.tool.summary ?? "",
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

    public func setAskBeforeSearching(_ value: Bool) async {
        settings.askBeforeSearching = value
        try? await store.setAskBeforeSearching(value)
        // Fan out to every active `ChatSession` so a long-running
        // conversation picks up the new gate on its next turn — otherwise
        // the persisted value would diverge from running sessions until
        // the user restarted the app.
        await webSearchPolicyReceiver.setAskBeforeSearching(value)
    }

    /// Master on/off for headless chat-title summarization. The summarizer
    /// model itself is `setTitleModelId`. No receiver fan-out needed — the
    /// title path (`TitleGenerator`) reads the setting fresh on each call.
    public func setSummarizeTitlesEnabled(_ value: Bool) async {
        settings.summarizeTitlesEnabled = value
        try? await store.setSummarizeTitlesEnabled(value)
    }

    /// Master on/off for in-app haptic feedback. Persists the flag and mutes
    /// the shared engine immediately via `setEnabled(_:)` so the change takes
    /// effect on the next tap without a relaunch.
    public func setHapticsEnabled(_ value: Bool) async {
        settings.hapticsEnabled = value
        hapticsEngine.setEnabled(value)
        try? await store.setHapticsEnabled(value)
    }

    /// Selects the model used to summarize chat titles. Pass `nil` for
    /// "automatic" (resolves to the Apple Foundation Model when available).
    /// Stores the summarizer's **record id** (`ModelRow.id` ==
    /// `ModelConfigurationRecord.id`), the unique per-model identity the title
    /// path resolves through `LLMProviderRegistry.provider(id:)`. Pass the row
    /// `id`, never `modelId` — two rows can share a `modelId`.
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

    /// Remembers the model the user just activated so the next new chat
    /// opens on it. Called by the host from `ChatScreenViewModel`'s
    /// `onModelSelected` hook (user picks in the composer) and from the
    /// initial auto-pick path in `AppShell.rebuildChatViewModel`.
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
    /// `true` when an `.appleFoundation` row already exists. The Add-Model
    /// preset picker uses this to disable the Apple Intelligence preset
    /// (one AFM row is enough — adding a second would only confuse the
    /// model list and `registerProvider` already gates on
    /// availability).
    public var hasAppleFoundationModel: Bool {
        models.contains { $0.kind == .appleFoundation }
    }

    /// Persist a new `.appleFoundation` row, register the live AFM
    /// provider (when the launch-time availability snapshot says AFM is
    /// usable), and refresh the in-memory list. Mirrors
    /// ``createModel(name:baseURL:modelId:apiKey:supportsThinking:maxContextTokens:kind:searchBackend:idGenerator:now:)``
    /// for the openAI-compatible kind, but skips the Keychain write (AFM
    /// rows have no API key) and force-sets the shape Apple's on-device
    /// model expects (`baseURL = nil`, `apiKeyRef = nil`, `modelId =
    /// "system-default"`). The `idGenerator` and `now` parameters are
    /// injectable so tests can pin the id and timestamp.
    ///
    /// Error contract matches `createModel`: on failure sets
    /// ``modelEditError`` and refreshes the list so the pane can show
    /// the message and the row count agrees with what actually persisted.
    public func createAppleFoundationModel(
        name: String,
        supportsThinking: Bool,
        maxContextTokens: Int,
        idGenerator: () -> String = { UUID().uuidString },
        now: Date = Date()
    ) async {
        modelEditError = nil
        let recordId = idGenerator()
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
            await registerProvider(for: record, apiKey: nil)
            await loadModels()
            onModelsChanged?()
        } catch {
            chatSettingsLog.error("createAppleFoundationModel failed: \(String(describing: error), privacy: .public)")
            modelEditError = "Could not save model: \(error.localizedDescription)"
            await loadModels()
        }
    }

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
        now: Date = Date()
    ) async {
        modelEditError = nil
        lastSavedModel = nil
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
                createdAt: now,
                // The picked web-search backend resolves the persisted kind:
                // native → the catalog's native adapter (e.g. `.openAIResponses`);
                // off / debug → `.openAICompatible`. The pane computes both from
                // the selected catalog entry.
                kind: kind,
                supportsThinking: supportsThinking,
                maxContextTokens: maxContextTokens,
                isSelected: false,
                searchBackend: searchBackend,
                providerId: providerId
            )
            try await modelRepository.save(record)
            lastSavedModel = record
            await eventBus?.publish(.credentialChanged(id: record.id))
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
    /// - Parameter searchSelection: The resolved `(kind, searchBackend)` the
    ///   web-search picker produced. `nil` (the default) preserves the row's
    ///   existing kind *and* search backend — keeping every non-search edit
    ///   path unchanged. When non-nil, both are rewritten: flipping Off↔Native
    ///   swaps the persisted `kind` (and base URL, supplied via `baseURL`) so
    ///   `makeLLMProvider` rebuilds the row as the native adapter or back.
    public func updateModel(
        id: String,
        name: String,
        baseURL: URL?,
        modelId: String,
        apiKey: String,
        supportsThinking: Bool,
        maxContextTokens: Int,
        searchSelection: (kind: LLMProviderKind, searchBackend: String?)? = nil,
        providerId: String? = nil
    ) async {
        modelEditError = nil
        lastSavedModel = nil
        do {
            guard let existing = try await modelRepository.fetch(id: id) else {
                modelEditError = "Could not save model: row no longer exists."
                return
            }
            // `.appleFoundation` rows have no `apiKeyRef`; guard avoids nil crash.
            if !apiKey.isEmpty, let ref = existing.apiKeyRef {
                try await modelRepository.storeAPIKey(apiKey, ref: ref)
                await eventBus?.publish(.credentialChanged(id: id))
            }
            // Target kind/backend: the picker's resolved pair when supplied,
            // else preserve what's on disk (every non-search edit).
            let targetKind = searchSelection?.kind ?? existing.kind
            let targetSearchBackend = searchSelection.map(\.searchBackend) ?? existing.searchBackend
            // Preserve existing `baseURL` for non-openAICompatible kinds.
            // For openAICompatible the caller passes the new URL (or
            // nil if it wasn't a field-driven change — in which case
            // we keep what we had). The switch (over an if/else)
            // forces the compiler to flag this site when a new
            // `LLMProviderKind` case is added so the URL-update rule
            // gets revisited rather than silently defaulting to
            // "preserve existing."
            let nextBaseURL: URL?
            switch targetKind {
            case .openAICompatible, .anthropicNative, .geminiNative, .openAIResponses:
                // openAICompatible and the native-search kinds all surface an
                // *editable* Base URL field in the edit pane — native kinds
                // route through the Custom pane (`resolveEditProvider`) until
                // PR3a gives them their own read-only catalog entry. While the
                // field is editable, honor the caller's URL rather than
                // silently discarding a user edit; `nil` means "no
                // field-driven change," so fall back to the persisted value.
                nextBaseURL = baseURL ?? existing.baseURL
            case .appleFoundation:
                // AFM has no URL field; preserve whatever was persisted (nil).
                nextBaseURL = existing.baseURL
            #if DEBUG
            case .debug:
                // Debug provider has no URL — preserve whatever was
                // persisted (always nil for canned-response rows).
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
                // Resolved by the web-search picker (or preserved when the
                // edit didn't touch search) — see `searchSelection`.
                searchBackend: targetSearchBackend,
                providerId: providerId ?? existing.providerId
            )
            try await modelRepository.save(updated)
            lastSavedModel = updated
            await eventBus?.publish(.credentialChanged(id: id))
            let resolvedKey: String?
            if !apiKey.isEmpty {
                resolvedKey = apiKey
            } else if let ref = existing.apiKeyRef {
                resolvedKey = try? await modelRepository.loadAPIKey(ref: ref)
            } else {
                resolvedKey = nil
            }
            // Build the replacement first; only swap when we actually have one
            // to register, so an edit never unregisters a working provider and
            // leaves nothing in its place (which would silently kill chat for
            // that row until restart). Building first makes the unregister
            // condition *exactly* what registration would do — no
            // `hasProviderAdapter` proxy that could drift from `makeLLMProvider`
            // (a kind can be buildable-by-kind yet yield no provider when the
            // row is missing its HTTP client or base URL, or AFM is
            // unavailable). The add paths still go through `registerProvider`.
            if let registry = llmProviderRegistry,
               let replacement = makeLLMProvider(
                   for: updated,
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
        do {
            try await modelRepository.delete(id: id)
            await llmProviderRegistry?.unregister(id: id)
            onModelsChanged?()
        } catch { modelEditError = "Could not remove the model. Try again." }
        // A Keychain-first deletion can remove the key even if the following database write fails.
        await eventBus?.publish(.credentialChanged(id: id))
        await loadModels()
    }

    /// Commits the visible audio draft after a model's credential has successfully saved.
    public func commitAudioSetup(enabled: Bool, useThisKey: Bool, revision: Int) async {
        guard let audioSetup, let row = lastSavedModel, let ref = row.apiKeyRef,
              ProviderAudioCredential.isDirectOpenAI(providerId: row.providerId, baseURL: row.baseURL) else { return }
        do {
            try await audioSetup.commit(
                ProviderAudioCredential(id: row.id, name: row.name, keyRef: ref), enabled, useThisKey, revision
            )
        } catch {
            modelEditError = "The model was saved, but narration settings were not. Review Narration settings and try again."
        }
    }

    /// Build a fresh provider for `record` and register it with the live
    /// registry. The per-kind dispatch is shared with the launch path
    /// (`AppBootstrapSupport.hydrateProviders`) through `makeLLMProvider`, so
    /// the two can't drift on which kinds are buildable: `.openAICompatible`
    /// and `.openAIResponses` need the injected HTTP client; `.appleFoundation`
    /// is skipped when AFM is unavailable; native-search kinds without a
    /// shipped adapter build nothing. No-op when no registry was injected
    /// (tests and previews don't wire one).
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
