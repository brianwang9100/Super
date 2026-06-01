import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `SettingsViewModel.load()` and the persistence-write
/// mutations. Each test seeds an in-memory `SettingRepository` plus stub
/// model and conversation repositories so we can verify both the
/// observable state and the on-disk effect of every setter.
@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    private static let appInfo = SuperAppInfo(bundleName: "Super", version: "0.3.1", build: "1")

    @Test("load falls back to ChatSettings.default for an empty store")
    func loadDefaults() async {
        let vm = makeViewModel()
        await vm.load()
        #expect(vm.settings == .default)
        #expect(vm.models.isEmpty)
        #expect(vm.tools.isEmpty)
        #expect(vm.chatCount == 0)
    }

    @Test("load reads every persisted key into the typed snapshot")
    func loadPersistedValues() async {
        let settingRepo = InMemorySettingRepository()
        try? await settingRepo.set(ChatSettingsStore.Keys.themeId, value: "dark")
        try? await settingRepo.set(ChatSettingsStore.Keys.userPersonalization, value: "Hello")
        try? await settingRepo.set(ChatSettingsStore.Keys.defaultVerbosity, value: "thinking")
        try? await settingRepo.set(ChatSettingsStore.Keys.fontScale, value: "1.1")
        try? await settingRepo.set(ChatSettingsStore.Keys.autoCompactEnabled, value: "false")
        try? await settingRepo.set(ChatSettingsStore.Keys.autoCompactThreshold, value: "0.7")
        try? await settingRepo.set(ChatSettingsStore.Keys.lastSelectedModelId, value: "claude-opus-4-7")

        let vm = makeViewModel(settingRepository: settingRepo)
        await vm.load()
        #expect(vm.settings.themeId == .dark)
        #expect(vm.settings.userPersonalization == "Hello")
        #expect(vm.settings.defaultVerbosity == .thinking)
        #expect(vm.settings.fontScale == 1.1)
        #expect(vm.settings.autoCompactEnabled == false)
        #expect(vm.settings.autoCompactThreshold == 0.7)
        #expect(vm.settings.lastSelectedModelId == "claude-opus-4-7")
    }

    @Test("setTheme persists and updates observable state")
    func setThemePersists() async {
        let settingRepo = InMemorySettingRepository()
        let vm = makeViewModel(settingRepository: settingRepo)
        await vm.setTheme(.sepia)
        #expect(vm.settings.themeId == .sepia)
        let raw = try? await settingRepo.get(ChatSettingsStore.Keys.themeId)
        #expect(raw == "sepia")
    }

    @Test("setFontScale clamps to the supported range")
    func setFontScaleClamps() async {
        let vm = makeViewModel()
        await vm.setFontScale(2.0)
        #expect(vm.settings.fontScale == 1.20)
        await vm.setFontScale(0.0)
        #expect(vm.settings.fontScale == 0.80)
    }

    @Test("setUserPersonalization persists immediately")
    func setUserPersonalizationPersists() async {
        let settingRepo = InMemorySettingRepository()
        let vm = makeViewModel(settingRepository: settingRepo)
        await vm.setUserPersonalization("New personalization body.")
        let raw = try? await settingRepo.get(ChatSettingsStore.Keys.userPersonalization)
        #expect(raw == "New personalization body.")
    }

    @Test("setUserPersonalization forwards to the receiver")
    func setUserPersonalizationForwardsToReceiver() async {
        // The fan-out hop
        // (`userPersonalizationReceiver.setUserPersonalization(value)`)
        // is what propagates a Settings edit to active `ChatSession`s in
        // production. Without this assertion, a future refactor that
        // drops the forwarding line would compile, persist correctly,
        // and leave every running conversation stuck on the old value
        // until app restart.
        let receiver = FakeUserPersonalizationReceiver()
        let vm = makeViewModel(userPersonalizationReceiver: receiver)
        await vm.setUserPersonalization("Always reply in haiku.")
        let received = await receiver.received()
        #expect(received == ["Always reply in haiku."])
    }

    @Test("setDefaultVerbosity round-trips through the store")
    func setDefaultVerbosityRoundTrip() async {
        let settingRepo = InMemorySettingRepository()
        let vm = makeViewModel(settingRepository: settingRepo)
        await vm.setDefaultVerbosity(.simple)
        let raw = try? await settingRepo.get(ChatSettingsStore.Keys.defaultVerbosity)
        #expect(raw == "simple")
        let reloaded = makeViewModel(settingRepository: settingRepo)
        await reloaded.load()
        #expect(reloaded.settings.defaultVerbosity == .simple)
    }

    @Test("setLastSelectedModelId persists and survives reload")
    func setLastSelectedModelIdRoundTrip() async {
        // Regression for the "new chats always pick the first registered
        // model" bug: the host writes the user's pick through this setter
        // so the next launch reads it back.
        let settingRepo = InMemorySettingRepository()
        let vm = makeViewModel(settingRepository: settingRepo)
        await vm.setLastSelectedModelId("claude-opus-4-7")

        #expect(vm.settings.lastSelectedModelId == "claude-opus-4-7")
        let raw = try? await settingRepo.get(ChatSettingsStore.Keys.lastSelectedModelId)
        #expect(raw == "claude-opus-4-7")

        let reloaded = makeViewModel(settingRepository: settingRepo)
        await reloaded.load()
        #expect(reloaded.settings.lastSelectedModelId == "claude-opus-4-7")
    }

    @Test("setAutoCompactThreshold clamps to allowed window")
    func setThresholdClamps() async {
        let vm = makeViewModel()
        await vm.setAutoCompactThreshold(2.0)
        #expect(vm.settings.autoCompactThreshold == 0.95)
        await vm.setAutoCompactThreshold(0.1)
        #expect(vm.settings.autoCompactThreshold == 0.5)
    }

    @Test("setAutoCompactEnabled forwards the new policy into the receiver")
    func setEnabledForwardsPolicy() async {
        // Same rationale as the system-prompt fan-out test above: without
        // this assertion, a refactor that drops the receiver call would
        // compile, persist the toggle to disk, and leave every running
        // session stuck on the old policy until app restart.
        let receiver = FakeAutoCompactPolicyReceiver()
        let vm = makeViewModel(autoCompactPolicyReceiver: receiver)
        await vm.setAutoCompactEnabled(false)
        let calls = await receiver.received()
        #expect(calls.count == 1)
        #expect(calls.last?.enabled == false)
        #expect(calls.last?.threshold == vm.settings.autoCompactThreshold)
    }

    @Test("setAutoCompactThreshold forwards the clamped policy into the receiver")
    func setThresholdForwardsPolicy() async {
        let receiver = FakeAutoCompactPolicyReceiver()
        let vm = makeViewModel(autoCompactPolicyReceiver: receiver)
        // Pick a value inside `clampThreshold`'s [0.5, 0.95] window so this
        // test pins the forwarding behavior, not the clamp boundary (which
        // is covered separately by `setThresholdClamps`).
        await vm.setAutoCompactThreshold(0.62)
        let calls = await receiver.received()
        #expect(calls.count == 1)
        #expect(calls.last?.enabled == vm.settings.autoCompactEnabled)
        #expect(calls.last?.threshold == 0.62)
    }

    @Test("setModelEnabled mutates the in-memory row and persists per-model flag")
    func setModelEnabled() async {
        let settingRepo = InMemorySettingRepository()
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "Test Model",
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKeyRef: "ref",
                modelId: "test",
                createdAt: Date(),
                supportsThinking: false,
                maxContextTokens: 8000,
                isSelected: true
            ),
        ])
        let vm = makeViewModel(
            settingRepository: settingRepo,
            modelRepository: modelRepo
        )
        await vm.load()
        #expect(vm.models.first?.isEnabled == true)

        await vm.setModelEnabled(id: "m1", enabled: false)
        #expect(vm.models.first?.isEnabled == false)
        let stored = try? await settingRepo.get(ChatSettingsStore.Keys.modelEnabled(id: "m1"))
        #expect(stored == "false")
    }

    @Test("setToolEnabled writes through ToolRegistry")
    func setToolEnabled() async {
        let registry = ToolRegistry()
        let tool = LLMTool(
            id: "demo.tool",
            name: "Demo Tool",
            description: "Used in tests",
            category: .system,
            parameters: [],
            appletId: "test"
        )
        await registry.register(ToolRegistration(
            tool: tool,
            execution: .local(StaticExecutor()),
            isEnabled: true
        ))
        let vm = makeViewModel(toolRegistry: registry)
        await vm.load()
        #expect(vm.tools.first?.isEnabled == true)

        await vm.setToolEnabled(id: "demo.tool", enabled: false)
        let registration = await registry.registration(toolID: "demo.tool")
        #expect(registration?.isEnabled == false)
    }

    @Test("clearChatHistory soft-deletes every active conversation")
    func clearChatHistory() async {
        let now = Date()
        let convoRepo = StubConversationRepository(rows: [
            .init(id: "a", title: "A", createdAt: now, updatedAt: now),
            .init(id: "b", title: "B", createdAt: now, updatedAt: now),
        ])
        let vm = makeViewModel(conversationRepository: convoRepo)
        await vm.load()
        #expect(vm.chatCount == 2)

        await vm.clearChatHistory(now: now)
        #expect(vm.chatCount == 0)
        #expect(convoRepo.rows.allSatisfy { $0.deletedAt != nil })
    }

    @Test("openPane appends to navigationPath; popPane / popToRoot reverse it")
    func navigationPathHelpers() async {
        let vm = makeViewModel()
        #expect(vm.navigationPath.isEmpty)

        vm.openPane(.models)
        #expect(vm.navigationPath == [.models])

        vm.openPane(.modelDetail(id: nil))
        #expect(vm.navigationPath == [.models, .modelDetail(id: nil)])

        vm.popPane()
        #expect(vm.navigationPath == [.models])

        vm.popToRoot()
        #expect(vm.navigationPath.isEmpty)

        // Opening .root from anywhere clears the stack so the header
        // header always reads "Settings".
        vm.openPane(.appearance)
        vm.openPane(.root)
        #expect(vm.navigationPath.isEmpty)
    }

    @Test("loadModels reports hasAPIKey true when a key is stored at the ref")
    func loadModelsFlagsKeychainPresence() async {
        // Drives the model-detail pane's "pre-fill the SecureField with
        // bullets" affordance: ModelRow.hasAPIKey is what the pane reads
        // at init time to decide whether to seed the placeholder. A
        // ref-with-no-entry must read as `false` so the pane shows an
        // empty field and prompts for a real key.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "with-key",
                name: "With Key",
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKeyRef: "ref-with",
                modelId: "gpt",
                createdAt: Date(),
                supportsThinking: false,
                maxContextTokens: 8_000,
                isSelected: false
            ),
            .init(
                id: "no-key",
                name: "No Key",
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKeyRef: "ref-without",
                modelId: "gpt",
                createdAt: Date().addingTimeInterval(1),
                supportsThinking: false,
                maxContextTokens: 8_000,
                isSelected: false
            ),
        ])
        modelRepo.storedKeys["ref-with"] = "sk-real"
        // ref-without intentionally absent from storedKeys

        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        let withKey = vm.models.first { $0.id == "with-key" }
        let noKey = vm.models.first { $0.id == "no-key" }
        #expect(withKey?.hasAPIKey == true)
        #expect(noKey?.hasAPIKey == false)
    }

    @Test("loadModels projects .appleFoundation rows with nil baseURL and empty endpoint")
    func loadModelsProjectsAppleFoundationRow() async {
        // The Settings UI consumes `ModelRow.kind` to render an AFM-aware
        // subtitle, `ModelRow.baseURL == nil` to suppress the endpoint
        // pill, and `ModelRow.hasAPIKey == false` since there is no
        // keychain entry to check. This exercises the three new
        // nil-aware branches in `loadModels()` against an AFM record.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "afm",
                name: "Apple Intelligence",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: "system-default",
                createdAt: Date(),
                kind: .appleFoundation,
                supportsThinking: false,
                maxContextTokens: 4_096,
                isSelected: true
            ),
        ])

        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        let row = vm.models.first { $0.id == "afm" }
        #expect(row?.kind == .appleFoundation)
        #expect(row?.baseURL == nil)
        #expect(row?.endpoint == "")
        #expect(row?.hasAPIKey == false)
        #expect(row?.modelId == "system-default")
    }

    @Test("updateModel on an .appleFoundation row preserves nil baseURL and skips keychain writes")
    func updateModelOnAppleFoundationRowPreservesNilFields() async {
        // Defense-in-depth against a non-nil URL leaking through the
        // pane (e.g., if a future refactor accidentally routes an
        // AFM edit through the openAI-compat save branch). The
        // openAI-compat URL must NOT overwrite the row's nil
        // `baseURL`, and the empty `apiKey` must NOT create a
        // phantom keychain entry under a nonexistent ref.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "afm",
                name: "Apple Intelligence",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: "system-default",
                createdAt: Date(),
                kind: .appleFoundation,
                supportsThinking: false,
                maxContextTokens: 4_096,
                isSelected: true
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.updateModel(
            id: "afm",
            name: "Apple Intelligence (renamed)",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "system-default",
            apiKey: "",
            supportsThinking: false,
            maxContextTokens: 4_096
        )

        let saved = try? await modelRepo.fetch(id: "afm")
        #expect(saved?.kind == .appleFoundation)
        #expect(saved?.baseURL == nil)            // form URL did NOT overwrite
        #expect(saved?.apiKeyRef == nil)
        #expect(saved?.name == "Apple Intelligence (renamed)")
        #expect(modelRepo.storedKeys.isEmpty)     // no phantom key written
    }

    @Test("updateModel on an .appleFoundation row with baseURL: nil preserves nil baseURL")
    func updateModelOnAppleFoundationRowWithNilBaseURL() async {
        // Regression test for the AFM edit path through `updateModel(baseURL: nil)`.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "afm",
                name: "Apple Intelligence",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: "system-default",
                createdAt: Date(),
                kind: .appleFoundation,
                supportsThinking: false,
                maxContextTokens: 4_096,
                isSelected: true
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        // Distinguishable name + thinking flip prove the write path ran.
        await vm.updateModel(
            id: "afm",
            name: "Apple Intelligence (renamed via nil-URL edit)",
            baseURL: nil,
            modelId: "system-default",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 8_192
        )

        let saved = try? await modelRepo.fetch(id: "afm")
        #expect(saved?.kind == .appleFoundation)
        #expect(saved?.baseURL == nil)
        #expect(saved?.apiKeyRef == nil)
        #expect(saved?.name == "Apple Intelligence (renamed via nil-URL edit)")
        #expect(saved?.supportsThinking == true)
        #expect(saved?.maxContextTokens == 8_192)
        #expect(modelRepo.storedKeys.isEmpty)
    }

    @Test("updateModel with blank key preserves both ref and stored key")
    func updateModelPlaceholderSavePreservesKey() async {
        // Pairs with the model-detail pane's "user opened the edit form
        // and saved without re-typing the key" path: the pane passes ""
        // for apiKey in that case, and the existing key must survive.
        // Stricter than `updateModelKeepsRef` above — that one asserts
        // `storedKeys.isEmpty` (no rotation), this one asserts the
        // original key is still readable through the repository after
        // the save round-trip.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "GPT",
                baseURL: URL(string: "https://x.example.com")!,
                apiKeyRef: "ref-1",
                modelId: "gpt",
                createdAt: Date(),
                supportsThinking: false,
                maxContextTokens: 8_000,
                isSelected: false
            ),
        ])
        modelRepo.storedKeys["ref-1"] = "sk-original"
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.updateModel(
            id: "m1",
            name: "GPT renamed",
            baseURL: URL(string: "https://x.example.com")!,
            modelId: "gpt",
            apiKey: "",
            supportsThinking: false,
            maxContextTokens: 8_000
        )

        // Key still readable through the repository — the placeholder
        // bullets must NOT have overwritten it.
        let resolved = try? await modelRepo.loadAPIKey(ref: "ref-1")
        #expect(resolved == "sk-original")
        // And the row continues to report hasAPIKey after the rename.
        let updated = vm.models.first { $0.id == "m1" }
        #expect(updated?.hasAPIKey == true)
        #expect(updated?.name == "GPT renamed")
    }

    @Test("hasAppleFoundationModel reflects the in-memory models list")
    func hasAppleFoundationModelTracksRows() async {
        // The preset picker uses this to disable the Apple Intelligence
        // option once an AFM row exists. The flag must agree with the
        // current in-memory snapshot — not a re-fetch — so a successful
        // `createAppleFoundationModel` immediately flips the bit.
        let modelRepo = StubModelRepository(rows: [])
        let vm = makeViewModel(
            modelRepository: modelRepo,
            appleFoundationAvailability: .available
        )
        await vm.load()
        #expect(vm.hasAppleFoundationModel == false)

        await vm.createAppleFoundationModel(
            name: "Apple Intelligence",
            supportsThinking: false,
            maxContextTokens: 4_096
        )

        #expect(vm.hasAppleFoundationModel == true)
    }

    @Test("createAppleFoundationModel writes AFM-shaped row and skips keychain")
    func createAppleFoundationModelPersists() async {
        let modelRepo = StubModelRepository(rows: [])
        let vm = makeViewModel(
            modelRepository: modelRepo,
            appleFoundationAvailability: .available
        )
        await vm.load()

        await vm.createAppleFoundationModel(
            name: "Apple Intelligence",
            supportsThinking: false,
            maxContextTokens: 4_096,
            idGenerator: { "afm-id" },
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(vm.models.count == 1)
        let saved = modelRepo.rows.first
        #expect(saved?.id == "afm-id")
        #expect(saved?.name == "Apple Intelligence")
        #expect(saved?.kind == .appleFoundation)
        #expect(saved?.baseURL == nil)
        #expect(saved?.apiKeyRef == nil)
        #expect(saved?.modelId == "system-default")
        #expect(saved?.maxContextTokens == 4_096)
        // No keychain entry should have been written — AFM rows have no
        // ref.  The stub stores nothing under nil/empty refs, so the dict
        // remains empty.
        #expect(modelRepo.storedKeys.isEmpty)
        #expect(vm.modelEditError == nil)
    }

    @Test("createAppleFoundationModel surfaces repository failures via modelEditError")
    func createAppleFoundationModelSurfacesFailures() async {
        struct StubSaveError: Error, Sendable {}
        let modelRepo = StubModelRepository(rows: [])
        modelRepo.saveError = StubSaveError()
        let vm = makeViewModel(
            modelRepository: modelRepo,
            appleFoundationAvailability: .available
        )
        await vm.load()

        await vm.createAppleFoundationModel(
            name: "Apple Intelligence",
            supportsThinking: false,
            maxContextTokens: 4_096
        )

        #expect(vm.modelEditError != nil)
        #expect(vm.modelEditError?.contains("Could not save model") == true)
        #expect(vm.models.isEmpty)
        #expect(modelRepo.rows.isEmpty)
    }

    @Test("createModel writes to repository and refreshes models list")
    func createModelPersists() async {
        let modelRepo = StubModelRepository(rows: [])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()
        #expect(vm.models.isEmpty)

        await vm.createModel(
            name: "Local Llama",
            baseURL: URL(string: "https://api.example.com/v1")!,
            modelId: "llama-3",
            apiKey: "sk-test",
            supportsThinking: true,
            maxContextTokens: 32_000
        )

        #expect(vm.models.count == 1)
        let saved = modelRepo.rows.first
        #expect(saved?.name == "Local Llama")
        #expect(saved?.modelId == "llama-3")
        #expect(saved?.maxContextTokens == 32_000)
        #expect(saved?.supportsThinking == true)
        #expect(modelRepo.storedKeys[saved?.apiKeyRef ?? ""] == "sk-test")
    }

    @Test("createModel surfaces repository failures via modelEditError")
    func createModelSurfacesFailures() async {
        // Regression test for the silent-catch bug: a Keychain failure
        // (errSecMissingEntitlement on unsigned simulator builds) used
        // to swallow the error in `createModel`'s catch — the form
        // dismissed and the user saw nothing. Now the error must surface
        // through `modelEditError` so the detail pane can render it.
        struct StubKeychainError: Error, Sendable {}
        let modelRepo = StubModelRepository(rows: [])
        modelRepo.storeAPIKeyError = StubKeychainError()
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()
        #expect(vm.modelEditError == nil)

        await vm.createModel(
            name: "Local Llama",
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelId: "llama-3",
            apiKey: "sk-test",
            supportsThinking: false,
            maxContextTokens: 8_000
        )

        #expect(vm.modelEditError != nil)
        #expect(vm.modelEditError?.contains("Could not save model") == true)
        // The row must not appear — a failed save should leave the
        // models list empty, not show a row that's actually missing
        // from disk.
        #expect(vm.models.isEmpty)
        #expect(modelRepo.rows.isEmpty)
    }

    @Test("createModel clears a stale modelEditError on a successful retry")
    func createModelClearsErrorOnRetry() async {
        struct StubKeychainError: Error, Sendable {}
        let modelRepo = StubModelRepository(rows: [])
        modelRepo.storeAPIKeyError = StubKeychainError()
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        // First attempt fails and sets the error.
        await vm.createModel(
            name: "Local Llama",
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelId: "llama-3",
            apiKey: "sk-test",
            supportsThinking: false,
            maxContextTokens: 8_000
        )
        #expect(vm.modelEditError != nil)

        // Drop the failure and retry — error must clear on the next
        // entry into createModel, not linger across attempts.
        modelRepo.storeAPIKeyError = nil
        await vm.createModel(
            name: "Local Llama",
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelId: "llama-3",
            apiKey: "sk-test",
            supportsThinking: false,
            maxContextTokens: 8_000
        )
        #expect(vm.modelEditError == nil)
        #expect(vm.models.count == 1)
    }

    @Test("updateModel mutates fields without rotating the apiKeyRef when key blank")
    func updateModelKeepsRef() async {
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "GPT 5",
                baseURL: URL(string: "https://old.example.com/v1")!,
                apiKeyRef: "ref-1",
                modelId: "gpt-5",
                createdAt: Date(),
                supportsThinking: false,
                maxContextTokens: 64_000,
                isSelected: true
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.updateModel(
            id: "m1",
            name: "GPT 5.5",
            baseURL: URL(string: "https://new.example.com/v1")!,
            modelId: "gpt-5.5",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 128_000
        )
        let saved = modelRepo.rows.first
        #expect(saved?.name == "GPT 5.5")
        #expect(saved?.apiKeyRef == "ref-1")
        #expect(saved?.maxContextTokens == 128_000)
        #expect(saved?.isSelected == true)
        // Empty key means we don't rotate the Keychain entry.
        #expect(modelRepo.storedKeys.isEmpty)
    }

    @Test("updateModel writes a new key when one is supplied")
    func updateModelRotatesKey() async {
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "GPT",
                baseURL: URL(string: "https://x.example.com")!,
                apiKeyRef: "ref-1",
                modelId: "gpt",
                createdAt: Date(),
                supportsThinking: false,
                maxContextTokens: 8_000,
                isSelected: false
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.updateModel(
            id: "m1",
            name: "GPT",
            baseURL: URL(string: "https://x.example.com")!,
            modelId: "gpt",
            apiKey: "sk-rotated",
            supportsThinking: false,
            maxContextTokens: 8_000
        )
        #expect(modelRepo.storedKeys["ref-1"] == "sk-rotated")
    }

    @Test("updateModel preserves a configured searchBackend across an edit")
    func updateModelPreservesSearchBackend() async {
        // Regression: `updateModel` rebuilds the whole record from form
        // fields. The form has no web-search field, so the saved record must
        // carry `searchBackend` over from `existing` — otherwise editing any
        // other field (name, model id, key) silently resets the row to "no
        // web search". Dropping `searchBackend: existing.searchBackend` from
        // the rebuild makes this test fail.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "Old Name",
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKeyRef: "ref-1",
                modelId: "old-model",
                createdAt: Date(),
                supportsThinking: false,
                maxContextTokens: 8000,
                isSelected: false,
                searchBackend: "native"
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.updateModel(
            id: "m1",
            name: "New Name",
            baseURL: URL(string: "https://api.example.com/v2")!,
            modelId: "new-model",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 16000
        )
        let saved = modelRepo.rows.first
        #expect(saved?.searchBackend == "native")
    }

    @Test("updateModel does not unregister a native-kind provider it can't re-register")
    func updateModelKeepsNativeKindProviderRegistered() async {
        // Regression for the unregister-then-break trap: `updateModel`
        // rebuilds the record (preserving `existing.kind`), then unregisters
        // the old provider and calls `registerProvider`. For a native-search
        // kind, `registerProvider` is a no-op (no adapter yet) — so an
        // unconditional unregister would strip a provider that was registered
        // at hydration time and leave nothing behind. The `hasProviderAdapter`
        // guard must skip the unregister so the provider survives the edit.
        let registry = LLMProviderRegistry()
        // Stand in for the (future) native provider registered at hydration.
        let provider = FakeLLMProvider(
            id: "m1",
            model: LLMModel(id: "claude-opus-4-7", displayName: "Opus")
        )
        await registry.register(provider)
        #expect(await registry.provider(id: "m1") != nil)

        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "Opus (native search)",
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                apiKeyRef: "ref-1",
                modelId: "claude-opus-4-7",
                createdAt: Date(),
                kind: .anthropicNative,
                supportsThinking: true,
                maxContextTokens: 1_000_000,
                isSelected: false,
                searchBackend: "native"
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo, llmProviderRegistry: registry)

        await vm.updateModel(
            id: "m1",
            name: "Opus (renamed)",
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            modelId: "claude-opus-4-7",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 1_000_000
        )

        // The provider must still be registered — the edit didn't strip it.
        #expect(await registry.provider(id: "m1") != nil)
    }

    @Test("updateModel persists an edited Base URL for a native-kind row")
    func updateModelHonorsEditedURLForNativeKind() async {
        // Regression for the silent-URL-discard trap: `resolveEditProvider`
        // routes native-kind rows through the Custom edit pane, which renders
        // an *editable* Base URL field. If `updateModel`'s `nextBaseURL`
        // switch preserved `existing.baseURL` for native kinds, a user edit
        // would be accepted in the UI and silently dropped on save. The
        // switch must honor the caller's URL so what the field shows is what
        // gets persisted. Preserving `existing.baseURL` here fails this test.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "Opus (native search)",
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                apiKeyRef: "ref-1",
                modelId: "claude-opus-4-7",
                createdAt: Date(),
                kind: .anthropicNative,
                supportsThinking: true,
                maxContextTokens: 1_000_000,
                isSelected: false,
                searchBackend: "native"
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)

        await vm.updateModel(
            id: "m1",
            name: "Opus (native search)",
            baseURL: URL(string: "https://api.anthropic.com/v2")!,
            modelId: "claude-opus-4-7",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 1_000_000
        )

        let saved = modelRepo.rows.first
        #expect(saved?.baseURL == URL(string: "https://api.anthropic.com/v2")!)
    }

    @Test("updateModel re-registers an openAICompatible provider across an edit")
    func updateModelReregistersBuildableProvider() async {
        // Counterpart to the native-kind test: for a buildable kind the
        // guard still allows the normal unregister + re-register cycle, so a
        // provider remains registered (under a possibly-rebuilt instance).
        let registry = LLMProviderRegistry()
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "GPT",
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKeyRef: "ref-1",
                modelId: "gpt-5.5",
                createdAt: Date(),
                kind: .openAICompatible,
                supportsThinking: false,
                maxContextTokens: 8000,
                isSelected: false
            ),
        ])
        let vm = makeViewModel(
            modelRepository: modelRepo,
            llmProviderRegistry: registry,
            httpClient: StubHTTPClient()
        )

        await vm.updateModel(
            id: "m1",
            name: "GPT renamed",
            baseURL: URL(string: "https://api.example.com/v1")!,
            modelId: "gpt-5.5",
            apiKey: "",
            supportsThinking: false,
            maxContextTokens: 8000
        )

        #expect(await registry.provider(id: "m1") != nil)
    }

    @Test("loadModels projects searchBackend onto the ModelRow")
    func loadModelsProjectsSearchBackend() async {
        // The Add-Model native-search UI (next PR) reads `searchBackend` off
        // the loaded `ModelRow`. If `loadModels` drops it, the toggle reads
        // `nil` and shows "off" for a row that has search configured.
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "withSearch",
                name: "With Search",
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKeyRef: "ref-1",
                modelId: "m",
                createdAt: Date(timeIntervalSince1970: 1),
                searchBackend: "native"
            ),
            .init(
                id: "noSearch",
                name: "No Search",
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKeyRef: "ref-2",
                modelId: "m",
                createdAt: Date(timeIntervalSince1970: 2)
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()
        #expect(vm.model(id: "withSearch")?.searchBackend == "native")
        #expect(vm.model(id: "noSearch")?.searchBackend == nil)
    }

    @Test("deleteModel removes the row and refreshes the list")
    func deleteModelClears() async {
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "GPT",
                baseURL: URL(string: "https://x.example.com")!,
                apiKeyRef: "ref-1",
                modelId: "gpt",
                createdAt: Date(),
                supportsThinking: false,
                maxContextTokens: 8_000,
                isSelected: false
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()
        #expect(vm.models.count == 1)

        await vm.deleteModel(id: "m1")
        #expect(vm.models.isEmpty)
        #expect(modelRepo.rows.isEmpty)
    }

    @Test("monogram splits on space, dash, and underscore")
    func monogramShape() {
        #expect(SettingsViewModel.monogram(for: "Opus 4.7") == "O4")
        #expect(SettingsViewModel.monogram(for: "Qwen3.6") == "Q")
        #expect(SettingsViewModel.monogram(for: "GPT 5.5") == "G5")
        #expect(SettingsViewModel.monogram(for: "claude-3-opus") == "c3")
        #expect(SettingsViewModel.monogram(for: "gpt_4o_mini") == "g4")
    }

    @Test("shortEndpoint trims scheme and trailing slash")
    func shortEndpoint() {
        #expect(SettingsViewModel.shortEndpoint(URL(string: "https://api.example.com/v1/")!) == "api.example.com/v1")
        #expect(SettingsViewModel.shortEndpoint(URL(string: "http://localhost:1234/")!) == "localhost:1234")
        // Schemes other than http/https pass through unchanged.
        #expect(SettingsViewModel.shortEndpoint(URL(string: "file:///tmp/local")!) == "file:///tmp/local")
    }

    // MARK: - Memory CRUD

    @Test("updateMemory writes trimmed text and the injected updatedAt")
    func updateMemoryUsesInjectedNow() async throws {
        let db = try ChatDatabase.makeInMemory()
        let repo = GRDBMemoryRepository(database: db)
        let seedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.save(MemoryEntry(
            id: "mem-1", text: "old", createdAt: seedDate, updatedAt: seedDate
        ))

        let vm = makeViewModel(memoryRepository: repo)
        let pinned = Date(timeIntervalSince1970: 1_700_000_900)
        await vm.updateMemory(id: "mem-1", text: "  new  ", now: pinned)

        let stored = try await repo.fetch(id: "mem-1")
        #expect(stored?.text == "new")
        // Pins the injection seam: without `now:` defaulting to Date(),
        // this assertion would race the wall clock — the regression
        // signal AGENTS.md §Testing rule 1 calls for.
        #expect(stored?.updatedAt == pinned)
        // createdAt must not move on update — surfaces would re-sort
        // and the system-prompt memories block would flicker.
        #expect(stored?.createdAt == seedDate)
    }

    @Test("updateMemory silently ignores empty / whitespace-only text")
    func updateMemoryIgnoresBlank() async throws {
        let db = try ChatDatabase.makeInMemory()
        let repo = GRDBMemoryRepository(database: db)
        let seedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.save(MemoryEntry(
            id: "mem-1", text: "keep me", createdAt: seedDate, updatedAt: seedDate
        ))

        let vm = makeViewModel(memoryRepository: repo)
        await vm.updateMemory(id: "mem-1", text: "   \n  ", now: seedDate.addingTimeInterval(60))

        let stored = try await repo.fetch(id: "mem-1")
        #expect(stored?.text == "keep me")
        #expect(stored?.updatedAt == seedDate)
    }

    @Test("deleteMemory removes the row")
    func deleteMemoryRemovesRow() async throws {
        let db = try ChatDatabase.makeInMemory()
        let repo = GRDBMemoryRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.save(MemoryEntry(id: "m1", text: "A", createdAt: now, updatedAt: now))
        try await repo.save(MemoryEntry(id: "m2", text: "B", createdAt: now.addingTimeInterval(1), updatedAt: now.addingTimeInterval(1)))

        let vm = makeViewModel(memoryRepository: repo)
        await vm.deleteMemory(id: "m1")

        let remaining = try await repo.all().map(\.id)
        #expect(remaining == ["m2"])
    }

    @Test("clearAllMemories wipes everything")
    func clearAllWipesEverything() async throws {
        let db = try ChatDatabase.makeInMemory()
        let repo = GRDBMemoryRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            try await repo.save(MemoryEntry(
                id: "m\(i)", text: "fact \(i)",
                createdAt: now.addingTimeInterval(TimeInterval(i)),
                updatedAt: now.addingTimeInterval(TimeInterval(i))
            ))
        }

        let vm = makeViewModel(memoryRepository: repo)
        await vm.clearAllMemories()

        #expect(try await repo.all().isEmpty)
    }

    @Test("memory mutations no-op when no memoryRepository is wired")
    func memoryMutationsNoopWithoutRepository() async {
        // Snapshot tests and the bare VM rely on this — without the
        // `guard let memoryRepository else { return }` early-return,
        // tapping CRUD affordances would crash. Pin the no-op contract.
        let vm = makeViewModel()
        await vm.updateMemory(id: "anything", text: "x", now: Date())
        await vm.deleteMemory(id: "anything")
        await vm.clearAllMemories()
        // No assertion needed — the absence of a crash IS the contract.
    }

    // MARK: - Builders

    private func makeViewModel(
        settingRepository: any SettingRepository = InMemorySettingRepository(),
        modelRepository: any ModelConfigurationRepository = StubModelRepository(rows: []),
        conversationRepository: any ConversationRepository = StubConversationRepository(rows: []),
        toolRegistry: ToolRegistry = ToolRegistry(),
        userPersonalizationReceiver: any UserPersonalizationReceiver = FakeUserPersonalizationReceiver(),
        autoCompactPolicyReceiver: any AutoCompactPolicyReceiver = FakeAutoCompactPolicyReceiver(),
        memoryRepository: (any MemoryRepository)? = nil,
        llmProviderRegistry: LLMProviderRegistry? = nil,
        httpClient: (any HTTPClient)? = nil,
        appleFoundationAvailability: AppleFoundationAvailability = .unavailable(.deviceNotEligible)
    ) -> SettingsViewModel {
        // The availability default is *deliberately* a fixed unavailable
        // case rather than the SDK's `SystemLanguageModel.default
        // .availability` so unit tests don't pick up whatever AFM state
        // happens to be on the host running them. Tests that need to
        // exercise the AFM-available code path should pass
        // `appleFoundationAvailability: .available` explicitly.
        SettingsViewModel(
            accountEmail: "test@example.com",
            appInfo: Self.appInfo,
            settingRepository: settingRepository,
            modelRepository: modelRepository,
            conversationRepository: conversationRepository,
            toolRegistry: toolRegistry,
            userPersonalizationReceiver: userPersonalizationReceiver,
            autoCompactPolicyReceiver: autoCompactPolicyReceiver,
            memoryRepository: memoryRepository,
            llmProviderRegistry: llmProviderRegistry,
            httpClient: httpClient,
            appleFoundationAvailability: appleFoundationAvailability
        )
    }
}

// MARK: - Test doubles

private actor InMemorySettingRepository: SettingRepository {
    private var storage: [String: String] = [:]

    func get(_ key: String) async throws -> String? { storage[key] }
    func set(_ key: String, value: String) async throws { storage[key] = value }
    func delete(_ key: String) async throws { storage.removeValue(forKey: key) }
    func all() async throws -> [String: String] { storage }
}

private final class StubModelRepository: ModelConfigurationRepository, @unchecked Sendable {
    var rows: [ModelConfigurationRecord]
    /// Plaintext keys keyed by ref so the createModel/updateModel tests
    /// can assert what landed in the Keychain layer.
    var storedKeys: [String: String] = [:]
    /// When non-nil, `storeAPIKey` throws this. Lets a test drive
    /// `createModel`/`updateModel` through the Keychain-failure path —
    /// the regression seam for the silent-catch bug fixed by surfacing
    /// `SettingsViewModel.modelEditError`.
    var storeAPIKeyError: Error?
    /// When non-nil, `save` throws this. Lets a test drive
    /// `createAppleFoundationModel` through the persistence-failure
    /// path; AFM rows never call `storeAPIKey`, so the existing
    /// `storeAPIKeyError` seam can't trip the error branch.
    var saveError: Error?

    init(rows: [ModelConfigurationRecord]) {
        self.rows = rows
    }

    func all() async throws -> [ModelConfigurationRecord] { rows }
    func fetch(id: String) async throws -> ModelConfigurationRecord? { rows.first { $0.id == id } }
    /// Mirrors `GRDBModelConfigurationRepository.selected()`, which filters
    /// the selection through `buildableKindRequest` — a selected row whose
    /// kind has no shipped adapter (the native-search kinds) is excluded so
    /// hydration's `setActive` never sees an unbuildable id. Keeping the stub
    /// in step avoids a future `isSelected: true` native-row test validating
    /// against behavior production doesn't have.
    func selected() async throws -> ModelConfigurationRecord? {
        rows.first { $0.isSelected && $0.kind.hasProviderAdapter }
    }
    func save(_ record: ModelConfigurationRecord) async throws {
        if let error = saveError { throw error }
        rows.removeAll { $0.id == record.id }
        rows.append(record)
    }
    func insertIfEmpty(
        make: @Sendable () -> ModelConfigurationRecord
    ) async throws -> ModelConfigurationRecord? {
        guard rows.isEmpty else { return nil }
        let record = make()
        rows.append(record)
        return record
    }
    func delete(id: String) async throws {
        rows.removeAll { $0.id == id }
        storedKeys[id] = nil
    }
    func setSelected(id: String) async throws {}
    func storeAPIKey(_ key: String, ref: String) async throws {
        if let error = storeAPIKeyError { throw error }
        storedKeys[ref] = key
    }
    func loadAPIKey(ref: String) async throws -> String? { storedKeys[ref] }
}

private final class StubConversationRepository: ConversationRepository, @unchecked Sendable {
    var rows: [ConversationRecord]

    init(rows: [ConversationRecord]) { self.rows = rows }

    func listActive() async throws -> [ConversationRecord] {
        rows.filter { $0.deletedAt == nil }
    }
    func listActiveRecent(limit: Int) async throws -> [ConversationRecord] {
        let active = rows
            .filter { $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Array(active.prefix(limit))
    }
    func fetch(id: String) async throws -> ConversationRecord? { rows.first { $0.id == id } }
    func save(_ record: ConversationRecord) async throws {
        rows.removeAll { $0.id == record.id }
        rows.append(record)
    }
    func softDelete(id: String, at deletedAt: Date) async throws {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        var updated = rows[idx]
        updated.deletedAt = deletedAt
        updated.updatedAt = deletedAt
        rows[idx] = updated
    }
    func hardDelete(id: String) async throws { rows.removeAll { $0.id == id } }
}

/// Minimal `HTTPClient` so `registerProvider` can build an
/// `OpenAICompatibleLLMProvider` in tests that exercise the registry path.
/// Never actually streamed in these tests (the provider is registered, not
/// invoked), so it yields an empty body.
private struct StubHTTPClient: HTTPClient {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StaticExecutor: ToolExecutor {
    let toolID: String = "demo.tool"

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        ToolResult(toolID: toolID, content: "ok")
    }
}
