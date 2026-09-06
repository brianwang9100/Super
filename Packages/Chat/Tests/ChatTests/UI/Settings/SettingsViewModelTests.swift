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
        #expect(vm.settings.themeId == .vellumDark)
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
        await vm.setTheme(.lapisLight)
        #expect(vm.settings.themeId == .lapisLight)
        let raw = try? await settingRepo.get(ChatSettingsStore.Keys.themeId)
        #expect(raw == "lapisLight")
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

    @Test("setAskBeforeSearching persists and forwards the gate into the receiver")
    func setAskBeforeSearchingForwardsGate() async {
        // Same rationale as the auto-compact fan-out tests: without this
        // assertion a refactor that drops the receiver call would compile,
        // persist the toggle to disk, and leave every running session stuck
        // on the old gate until app restart.
        let repo = InMemorySettingRepository()
        let receiver = FakeWebSearchPolicyReceiver()
        let vm = makeViewModel(settingRepository: repo, webSearchPolicyReceiver: receiver)
        await vm.setAskBeforeSearching(false)

        #expect(vm.settings.askBeforeSearching == false)
        let calls = await receiver.received()
        #expect(calls == [false])
        // Persisted under the canonical key so the value survives relaunch.
        let stored = try? await repo.get(ChatSettingsStore.Keys.webSearchAskBeforeSearching)
        #expect(stored == "false")
    }

    @Test("setHapticsEnabled persists, updates state, and mutes the shared engine")
    func setHapticsEnabledPersistsAndMutesEngine() async {
        let repo = InMemorySettingRepository()
        let engine = RecordingHapticsEngine()
        let vm = makeViewModel(settingRepository: repo, hapticsEngine: engine)
        await vm.setHapticsEnabled(false)

        #expect(vm.settings.hapticsEnabled == false)
        // The shared engine was muted immediately (live, no relaunch).
        #expect(engine.enabledLog == [false])
        // Persisted under the canonical key so the value survives relaunch.
        let stored = try? await repo.get(ChatSettingsStore.Keys.hapticsEnabled)
        #expect(stored == "false")
    }

    @Test("hapticsEnabled round-trips through ChatSettingsStore")
    func hapticsEnabledRoundTripsThroughStore() async {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        // Default is on when the row is absent.
        let beforeWrite = await store.load()
        #expect(beforeWrite.hapticsEnabled == true)

        try? await store.setHapticsEnabled(false)
        let afterWrite = await store.load()
        #expect(afterWrite.hapticsEnabled == false)
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
        #expect(row?.endpoint.isEmpty == true)
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

    @Test("appleFoundationContextTokens surfaces the injected on-device window")
    func appleFoundationContextTokensIsInjected() async {
        // The detail pane renders + persists this value for AFM rows (the
        // field is read-only). Injecting it keeps the pane deterministic and
        // off the real device API; a distinctive value proves it's wired
        // through rather than a hardcoded 4096.
        let vm = makeViewModel(appleFoundationContextTokens: 9_999)
        #expect(vm.appleFoundationContextTokens == 9_999)
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

    @Test("Local and PCC registrations coexist with independent IDs and metadata")
    func appleModelVariantsCanCoexist() async {
        let repository = StubModelRepository(rows: [])
        let statusProvider = makeAppleStatusProvider()
        let vm = makeViewModel(modelRepository: repository, appleFoundationStatusProvider: statusProvider)
        let ids = DeterministicIDGenerator(prefix: "apple-")
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        await vm.load()
        #expect(vm.preferredAppleFoundationModel == .privateCloudCompute)

        for model in AppleFoundationModel.allCases {
            await vm.createAppleFoundationModel(
                name: model.displayName, supportsThinking: true, maxContextTokens: 123,
                model: model, idGenerator: { ids.nextID() }, now: clock.now()
            )
            #expect(vm.modelEditError == nil)
        }

        #expect(repository.rows.map(\.id) == ["apple-1", "apple-2"])
        #expect(repository.rows.map(\.modelId) == AppleFoundationModel.allCases.map(\.rawValue))
        #expect(repository.rows.map(\.maxContextTokens) == [8_192, 24_000])
        #expect(repository.rows.allSatisfy {
            $0.kind == .appleFoundation && $0.baseURL == nil && $0.apiKeyRef == nil
                && !$0.supportsThinking && !$0.isSelected && $0.createdAt == clock.now()
        })
        #expect(repository.storedKeys.isEmpty)
        #expect(vm.hasAppleFoundationModel(.local))
        #expect(vm.hasAppleFoundationModel(.privateCloudCompute))
        #expect(vm.preferredAppleFoundationModel == nil)
    }

    @Test("Duplicate Apple registration is rejected per variant without allocating another ID",
          arguments: AppleFoundationModel.allCases)
    func duplicateAppleVariantIsRejected(model: AppleFoundationModel) async {
        let repository = StubModelRepository(rows: [])
        let vm = makeViewModel(modelRepository: repository, appleFoundationStatusProvider: makeAppleStatusProvider())
        let ids = DeterministicIDGenerator(prefix: "duplicate-")
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        await vm.load()

        await vm.createAppleFoundationModel(
            name: model.displayName, supportsThinking: false, maxContextTokens: 1,
            model: model, idGenerator: { ids.nextID() }, now: clock.now()
        )
        let saved = repository.rows
        await vm.createAppleFoundationModel(
            name: "Duplicate", supportsThinking: false, maxContextTokens: 1,
            model: model, idGenerator: { ids.nextID() }, now: clock.now()
        )

        #expect(repository.rows == saved)
        #expect(vm.modelEditError?.contains("already added") == true)
        #expect(ids.nextID() == "duplicate-2")
        #expect(!vm.isSavingAppleModel)
        let other: AppleFoundationModel = model == .local ? .privateCloudCompute : .local
        #expect(vm.appleFoundationRegistrationIssue(for: other) == nil)
        #expect(vm.preferredAppleFoundationModel == other)
    }

    @Test("Duplicate checks consult persistence even when the Models list is stale",
          arguments: AppleFoundationModel.allCases)
    func appleDuplicateInsertedOutsideTheViewModelIsRejected(model: AppleFoundationModel) async throws {
        let repository = StubModelRepository(rows: [])
        let vm = makeViewModel(modelRepository: repository, appleFoundationStatusProvider: makeAppleStatusProvider())
        let ids = DeterministicIDGenerator(prefix: "unused-")
        let clock = FixedClock(Date(timeIntervalSince1970: 200))
        await vm.load()
        let existing = ModelConfigurationRecord(
            id: "outside-row", name: "Existing choice", baseURL: nil, apiKeyRef: nil,
            modelId: model.rawValue, createdAt: clock.now(), kind: .appleFoundation,
            isSelected: true
        )
        try await repository.save(existing)
        #expect(!vm.hasAppleFoundationModel(model))

        await vm.createAppleFoundationModel(
            name: model.displayName, supportsThinking: false, maxContextTokens: 1,
            model: model, idGenerator: { ids.nextID() }, now: clock.now()
        )

        #expect(repository.rows == [existing])
        #expect(vm.hasAppleFoundationModel(model))
        #expect(vm.modelEditError?.contains("already added") == true)
        #expect(ids.nextID() == "unused-1")
    }

    @Test("iOS 26 cannot save PCC even if a caller bypasses the disabled picker")
    func unsupportedOSRejectsCloudRegistration() async {
        let repository = StubModelRepository(rows: [])
        let vm = makeViewModel(
            modelRepository: repository,
            appleFoundationStatusProvider: makeAppleStatusProvider(supportsPrivateCloudCompute: false)
        )
        let ids = DeterministicIDGenerator(prefix: "unused-")
        await vm.load()
        #expect(!vm.supportsPrivateCloudCompute)
        #expect(vm.preferredAppleFoundationModel == .local)

        await vm.createAppleFoundationModel(
            name: "PCC", supportsThinking: false, maxContextTokens: 32_000,
            model: .privateCloudCompute, idGenerator: { ids.nextID() },
            now: Date(timeIntervalSince1970: 300)
        )

        #expect(vm.modelEditError == "Private Cloud Compute requires iOS 27 or later.")
        #expect(repository.rows.isEmpty)
        #expect(repository.storedKeys.isEmpty)
        #expect(ids.nextID() == "unused-1")
        #expect(!vm.isSavingAppleModel)
    }

    @Test("PCC registration does not depend on the on-device model download")
    func cloudReadinessIsIndependentOfLocalReadiness() async {
        let repository = StubModelRepository(rows: [])
        let vm = makeViewModel(
            modelRepository: repository,
            appleFoundationStatusProvider: makeAppleStatusProvider(localAvailability: .unavailable(.modelNotReady))
        )
        let ids = DeterministicIDGenerator(prefix: "cloud-")
        await vm.load()
        #expect(!vm.appleFoundationStatus(for: .local).canGenerate)
        #expect(vm.appleFoundationStatus(for: .privateCloudCompute).canGenerate)
        #expect(vm.appleFoundationRegistrationIssue(for: .local) != nil)
        #expect(vm.appleFoundationRegistrationIssue(for: .privateCloudCompute) == nil)
        #expect(vm.preferredAppleFoundationModel == .privateCloudCompute)

        await vm.createAppleFoundationModel(
            name: "My cloud model", supportsThinking: false, maxContextTokens: 1,
            model: .privateCloudCompute, idGenerator: { ids.nextID() },
            now: Date(timeIntervalSince1970: 400)
        )

        #expect(vm.modelEditError == nil)
        #expect(repository.rows.first?.modelId == AppleFoundationModel.privateCloudCompute.rawValue)
        #expect(repository.rows.first?.maxContextTokens == 24_000)
    }

    @Test("Unavailable PCC does not block local registration or leave a stale save error")
    func unavailableCloudDoesNotBlockLocalRegistration() async {
        let repository = StubModelRepository(rows: [])
        let vm = makeViewModel(
            modelRepository: repository,
            appleFoundationStatusProvider: makeAppleStatusProvider(cloudAvailability: .unavailable(.systemNotReady))
        )
        let ids = DeterministicIDGenerator(prefix: "local-")
        let clock = FixedClock(Date(timeIntervalSince1970: 450))
        await vm.load()
        #expect(vm.preferredAppleFoundationModel == .local)

        await vm.createAppleFoundationModel(
            name: "Unavailable PCC", supportsThinking: false, maxContextTokens: 1,
            model: .privateCloudCompute, idGenerator: { ids.nextID() }, now: clock.now()
        )
        #expect(vm.modelEditError != nil)
        #expect(repository.rows.isEmpty)
        await vm.createAppleFoundationModel(
            name: "Local only", supportsThinking: false, maxContextTokens: 1,
            model: .local, idGenerator: { ids.nextID() }, now: clock.now()
        )

        #expect(vm.modelEditError == nil)
        #expect(repository.rows.map(\.id) == ["local-1"])
        #expect(repository.rows.first?.modelId == AppleFoundationModel.local.rawValue)
        #expect(repository.rows.first?.maxContextTokens == 8_192)
    }

    @Test("Quota exhaustion blocks generation but does not prevent saving a PCC configuration")
    func exhaustedQuotaDoesNotBlockCloudRegistration() async {
        let repository = StubModelRepository(rows: [])
        let reset = Date(timeIntervalSince1970: 1_700_086_400)
        let vm = makeViewModel(
            modelRepository: repository,
            appleFoundationStatusProvider: makeAppleStatusProvider(
                cloudQuota: .init(state: .limitReached, resetDate: reset)
            )
        )
        let ids = DeterministicIDGenerator(prefix: "quota-")
        await vm.load()
        #expect(vm.appleFoundationRegistrationIssue(for: .privateCloudCompute) == nil)
        #expect(!vm.appleFoundationStatus(for: .privateCloudCompute).canGenerate)
        #expect(vm.appleFoundationStatus(for: .privateCloudCompute).quota?.resetDate == reset)
        #expect(vm.appleFoundationStatusMessage(for: .privateCloudCompute)?.contains("daily usage limit") == true)

        await vm.createAppleFoundationModel(
            name: "PCC after reset", supportsThinking: false, maxContextTokens: 1,
            model: .privateCloudCompute, idGenerator: { ids.nextID() },
            now: Date(timeIntervalSince1970: 500)
        )

        #expect(vm.modelEditError == nil)
        #expect(repository.rows.first?.modelId == AppleFoundationModel.privateCloudCompute.rawValue)
        #expect(!vm.appleFoundationStatus(for: .privateCloudCompute).canGenerate)
    }

    @Test("Saving an Apple edit cannot convert local to PCC or PCC to local",
          arguments: AppleFoundationModel.allCases)
    func appleEditPreservesSavedVariant(model: AppleFoundationModel) async {
        let existing = ModelConfigurationRecord(
            id: "saved-apple", name: "Saved choice", baseURL: nil, apiKeyRef: nil,
            modelId: model.rawValue, createdAt: Date(timeIntervalSince1970: 600),
            kind: .appleFoundation, maxContextTokens: 8_000, isSelected: true
        )
        let repository = StubModelRepository(rows: [existing])
        let vm = makeViewModel(modelRepository: repository, appleFoundationStatusProvider: makeAppleStatusProvider())
        await vm.load()
        let other: AppleFoundationModel = model == .local ? .privateCloudCompute : .local

        await vm.updateModel(
            id: existing.id, name: "Changed backend", baseURL: nil,
            modelId: other.rawValue, apiKey: "", supportsThinking: false, maxContextTokens: 1
        )

        #expect(repository.rows == [existing])
        #expect(vm.models.first?.modelId == model.rawValue)
        #expect(vm.modelEditError?.contains("separately") == true)
        #expect(repository.storedKeys.isEmpty)
    }

    @Test("A restored PCC row can be renamed on iOS 26 without changing its identity")
    func unsupportedCloudEditKeepsRecordIdentity() async {
        let existing = ModelConfigurationRecord(
            id: "restored-pcc", name: "Original cloud name", baseURL: nil, apiKeyRef: nil,
            modelId: AppleFoundationModel.privateCloudCompute.rawValue,
            createdAt: Date(timeIntervalSince1970: 700), kind: .appleFoundation,
            maxContextTokens: 24_000, isSelected: true
        )
        let repository = StubModelRepository(rows: [existing])
        let vm = makeViewModel(modelRepository: repository,
                               appleFoundationStatusProvider: makeAppleStatusProvider(supportsPrivateCloudCompute: false))
        await vm.load()

        await vm.updateModel(
            id: existing.id, name: "Renamed cloud choice", baseURL: nil,
            modelId: existing.modelId, apiKey: "", supportsThinking: false,
            maxContextTokens: existing.maxContextTokens
        )

        var expected = existing
        expected.name = "Renamed cloud choice"
        #expect(repository.rows == [expected])
        #expect(vm.modelEditError == nil)
        #expect(!vm.appleFoundationStatus(for: .privateCloudCompute).canGenerate)
    }

    @Test("Editing either Apple variant preserves the active provider when both are registered",
          arguments: AppleFoundationModel.allCases)
    func editingAppleVariantDoesNotSelectItsSibling(model: AppleFoundationModel) async throws {
        let rows = makeAppleModelRecords()
        let repository = StubModelRepository(rows: rows)
        let registry = LLMProviderRegistry()
        for row in rows {
            await registry.register(FakeLLMProvider(
                id: row.id, model: LLMModel(id: row.modelId, displayName: row.name)
            ))
        }
        let existing = try #require(rows.first { $0.modelId == model.rawValue })
        try await registry.setActive(id: existing.id)
        let vm = makeViewModel(
            modelRepository: repository, llmProviderRegistry: registry,
            appleFoundationStatusProvider: makeAppleStatusProvider()
        )

        await vm.updateModel(
            id: existing.id, name: "Renamed Apple model", baseURL: nil,
            modelId: existing.modelId, apiKey: "", supportsThinking: false,
            maxContextTokens: existing.maxContextTokens
        )

        #expect(vm.modelEditError == nil)
        #expect(await registry.activeID() == existing.id)
        #expect(await registry.allProviders().count == 2)
        let replacement = try #require(await registry.provider(id: existing.id))
        #expect(replacement.kind == .appleFoundation)
        #expect(replacement.supportedModels.first?.id == existing.modelId)
        #expect(repository.rows.first { $0.id == existing.id }?.name == "Renamed Apple model")
    }

    @Test("An Apple edit cannot escape its backend through the search-kind selection")
    func appleEditRejectsSearchKindConversion() async {
        let existing = ModelConfigurationRecord(
            id: "apple-row", name: "Apple", baseURL: nil, apiKeyRef: nil,
            modelId: AppleFoundationModel.local.rawValue, createdAt: Date(timeIntervalSince1970: 800),
            kind: .appleFoundation, isSelected: true
        )
        let repository = StubModelRepository(rows: [existing])
        let vm = makeViewModel(modelRepository: repository)
        await vm.load()

        await vm.updateModel(
            id: existing.id, name: existing.name, baseURL: URL(string: "https://example.test/v1"),
            modelId: existing.modelId, apiKey: "synthetic-key", supportsThinking: false,
            maxContextTokens: 1, searchSelection: (.openAIResponses, "native")
        )

        #expect(repository.rows == [existing])
        #expect(repository.storedKeys.isEmpty)
        #expect(vm.modelEditError?.contains("separately") == true)
    }

    @Test("Explicit status refresh replaces stale readiness and quota after load has completed")
    func appleStatusesRefreshAfterInitialLoad() async {
        let unavailable = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .unavailable(.systemNotReady)
        )
        let provider = ScriptedAppleFoundationStatusProvider(cloudStatus: unavailable)
        let vm = makeViewModel(appleFoundationStatusProvider: provider)
        await vm.load()
        #expect(vm.appleFoundationStatus(for: .privateCloudCompute) == unavailable)
        #expect(vm.preferredAppleFoundationModel == .local)
        let refreshed = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .available, contextTokens: 24_000,
            quota: .init(state: .approachingLimit, resetDate: Date(timeIntervalSince1970: 900))
        )
        await provider.setCloudStatus(refreshed)

        await vm.refreshAppleFoundationStatuses()

        #expect(vm.appleFoundationStatus(for: .privateCloudCompute) == refreshed)
        #expect(vm.appleFoundationStatus(for: .privateCloudCompute).canGenerate)
        #expect(vm.appleFoundationStatusMessage(for: .privateCloudCompute) == "Approaching the daily PCC usage limit.")
        #expect(vm.preferredAppleFoundationModel == .privateCloudCompute)
        #expect(await provider.requestedModels() == [.local, .privateCloudCompute, .local, .privateCloudCompute])
    }

    @Test("Canceled Apple status refresh cannot publish readiness after the pane exits")
    func canceledAppleStatusRefreshDoesNotPublish() async {
        let provider = ScriptedAppleFoundationStatusProvider(
            cloudStatus: AppleFoundationModelStatus(
                model: .privateCloudCompute, availability: .available, contextTokens: 24_000
            ), gateFirstRequest: true
        )
        let vm = makeViewModel(appleFoundationStatusProvider: provider)
        let initialLocal = vm.appleFoundationStatus(for: .local)
        let initialCloud = vm.appleFoundationStatus(for: .privateCloudCompute)
        let refresh = Task { await vm.refreshAppleFoundationStatuses() }
        await provider.waitUntilGateEntered()

        refresh.cancel()
        await provider.releaseGate()
        await refresh.value

        #expect(vm.appleFoundationStatus(for: .local) == initialLocal)
        #expect(vm.appleFoundationStatus(for: .privateCloudCompute) == initialCloud)
        #expect(await provider.requestedModels() == [.local])
    }

    @Test("Overlapping Apple saves cannot both pass the per-view-model registration guard")
    func overlappingAppleSavesDoNotDuplicateTheModel() async {
        let provider = ScriptedAppleFoundationStatusProvider(
            cloudStatus: AppleFoundationModelStatus(
                model: .privateCloudCompute, availability: .available, contextTokens: 24_000
            ), gateFirstRequest: true
        )
        let repository = StubModelRepository(rows: [])
        let vm = makeViewModel(modelRepository: repository, appleFoundationStatusProvider: provider)
        let ids = DeterministicIDGenerator(prefix: "one-save-")
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let first = Task {
            await vm.createAppleFoundationModel(
                name: "PCC", supportsThinking: false, maxContextTokens: 1,
                model: .privateCloudCompute, idGenerator: { ids.nextID() }, now: clock.now()
            )
        }
        await provider.waitUntilGateEntered()
        #expect(vm.isSavingAppleModel)

        await vm.createAppleFoundationModel(
            name: "Duplicate PCC", supportsThinking: false, maxContextTokens: 1,
            model: .privateCloudCompute, idGenerator: { ids.nextID() }, now: clock.now()
        )
        await provider.releaseGate()
        await first.value

        #expect(repository.rows.map(\.id) == ["one-save-1"])
        #expect(repository.rows.first?.name == "PCC")
        #expect(ids.nextID() == "one-save-2")
        #expect(vm.modelEditError == nil)
        #expect(!vm.isSavingAppleModel)
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

    @Test("createModel persists the picker-resolved native kind + searchBackend")
    func createModelNativeBackend() async {
        let modelRepo = StubModelRepository(rows: [])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.createModel(
            name: "GPT-5.5",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "gpt-5.5",
            apiKey: "sk-test",
            supportsThinking: true,
            maxContextTokens: 200_000,
            kind: .openAIResponses,
            searchBackend: "native"
        )

        let saved = modelRepo.rows.first
        #expect(saved?.kind == .openAIResponses)
        #expect(saved?.searchBackend == "native")
    }

    @Test("createModel persists the debug mock backend on a compat kind")
    func createModelDebugBackend() async {
        let modelRepo = StubModelRepository(rows: [])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.createModel(
            name: "Mock",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "gpt-5.5",
            apiKey: "sk-test",
            supportsThinking: false,
            maxContextTokens: 200_000,
            searchBackend: "debug"
        )

        let saved = modelRepo.rows.first
        #expect(saved?.kind == .openAICompatible)
        #expect(saved?.searchBackend == "debug")
    }

    @Test("updateModel searchSelection swaps a compat row to a native kind + backend")
    func updateModelSearchSelectionNative() async {
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1", name: "GPT 5.5",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKeyRef: "ref-1", modelId: "gpt-5.5", createdAt: Date(),
                kind: .openAICompatible, supportsThinking: true,
                maxContextTokens: 200_000, isSelected: true
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.updateModel(
            id: "m1",
            name: "GPT 5.5",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "gpt-5.5",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 200_000,
            searchSelection: (kind: .openAIResponses, searchBackend: "native")
        )

        let saved = modelRepo.rows.first
        #expect(saved?.kind == .openAIResponses)
        #expect(saved?.searchBackend == "native")
    }

    @Test("updateModel searchSelection Off swaps a native row back to compat")
    func updateModelSearchSelectionOff() async {
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1", name: "GPT 5.5",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKeyRef: "ref-1", modelId: "gpt-5.5", createdAt: Date(),
                kind: .openAIResponses, supportsThinking: true,
                maxContextTokens: 200_000, isSelected: true, searchBackend: "native"
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.updateModel(
            id: "m1",
            name: "GPT 5.5",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "gpt-5.5",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 200_000,
            searchSelection: (kind: .openAICompatible, searchBackend: nil)
        )

        let saved = modelRepo.rows.first
        #expect(saved?.kind == .openAICompatible)
        #expect(saved?.searchBackend == nil)
    }

    @Test("updateModel with no searchSelection preserves the row's kind + searchBackend")
    func updateModelPreservesSearchWhenUnset() async {
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1", name: "GPT 5.5",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKeyRef: "ref-1", modelId: "gpt-5.5", createdAt: Date(),
                kind: .openAIResponses, supportsThinking: true,
                maxContextTokens: 200_000, isSelected: true, searchBackend: "native"
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo)
        await vm.load()

        await vm.updateModel(
            id: "m1",
            name: "Renamed",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "gpt-5.5",
            apiKey: "",
            supportsThinking: true,
            maxContextTokens: 200_000
        )

        let saved = modelRepo.rows.first
        #expect(saved?.name == "Renamed")
        #expect(saved?.kind == .openAIResponses)
        #expect(saved?.searchBackend == "native")
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

    @Test("updateModel does not unregister a provider it can't re-register")
    func updateModelKeepsNativeKindProviderRegistered() async {
        // Regression for the unregister-then-break trap: `updateModel` now
        // builds the replacement provider *first* and only swaps when it gets
        // one. Here the view model is wired with no HTTP client, so
        // `makeLLMProvider` yields nil for this network-backed `.geminiNative`
        // row — meaning an unconditional unregister would strip the provider
        // registered at hydration time and leave nothing behind. Building first
        // skips the unregister so the provider survives the edit. (This exactly
        // matches what re-registration would do — no `hasProviderAdapter` proxy
        // that could drift from the factory.)
        let registry = LLMProviderRegistry()
        // Stand in for the (future) native provider registered at hydration.
        let provider = FakeLLMProvider(
            id: "m1",
            model: LLMModel(id: "gemini-3-pro", displayName: "Gemini 3 Pro")
        )
        await registry.register(provider)
        #expect(await registry.provider(id: "m1") != nil)

        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "Gemini (native search)",
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
                apiKeyRef: "ref-1",
                modelId: "gemini-3-pro",
                createdAt: Date(),
                kind: .geminiNative,
                supportsThinking: true,
                maxContextTokens: 1_000_000,
                isSelected: false,
                searchBackend: "native"
            ),
        ])
        let vm = makeViewModel(modelRepository: modelRepo, llmProviderRegistry: registry)

        await vm.updateModel(
            id: "m1",
            name: "Gemini (renamed)",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            modelId: "gemini-3-pro",
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

    @Test("updateModel re-registers an .openAIResponses provider across an edit")
    func updateModelReregistersOpenAIResponsesProvider() async {
        // The PR3a `hasProviderAdapter` flip makes `.openAIResponses` rows
        // newly eligible for the unregister + re-register cycle. Pin it: after
        // an edit the row stays registered, built through `makeLLMProvider` as
        // an `OpenAIResponsesLLMProvider` (not silently dropped the way a
        // not-yet-buildable native kind would be).
        let registry = LLMProviderRegistry()
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "resp1",
                name: "GPT-5.1 (search)",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKeyRef: "ref-1",
                modelId: "gpt-5.1",
                createdAt: Date(),
                kind: .openAIResponses,
                supportsThinking: false,
                maxContextTokens: 200_000,
                isSelected: false,
                searchBackend: "native"
            ),
        ])
        let vm = makeViewModel(
            modelRepository: modelRepo,
            llmProviderRegistry: registry,
            httpClient: StubHTTPClient()
        )

        await vm.updateModel(
            id: "resp1",
            name: "GPT-5.1 renamed",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "gpt-5.1",
            apiKey: "",
            supportsThinking: false,
            maxContextTokens: 200_000
        )

        let provider = await registry.provider(id: "resp1")
        #expect(provider is OpenAIResponsesLLMProvider)
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

    @Test("Deleting one Apple variant keeps its sibling registered and selectable",
          arguments: AppleFoundationModel.allCases)
    func deletingAppleVariantPreservesItsSibling(model: AppleFoundationModel) async throws {
        let rows = makeAppleModelRecords()
        let repository = StubModelRepository(rows: rows)
        let registry = LLMProviderRegistry()
        for row in rows {
            await registry.register(FakeLLMProvider(
                id: row.id, model: LLMModel(id: row.modelId, displayName: row.name)
            ))
        }
        let deleted = try #require(rows.first { $0.modelId == model.rawValue })
        let retained = try #require(rows.first { $0.modelId != model.rawValue })
        try await registry.setActive(id: deleted.id)
        let vm = makeViewModel(modelRepository: repository, llmProviderRegistry: registry)

        let succeeded = await vm.deleteModel(id: deleted.id)

        #expect(succeeded)
        #expect(vm.modelEditError == nil)
        #expect(repository.rows == [retained])
        #expect(vm.models.map(\.id) == [retained.id])
        #expect(await registry.provider(id: deleted.id) == nil)
        #expect(await registry.provider(id: retained.id) != nil)
        #expect(await registry.activeID() == retained.id)
    }

    @Test("Failed Apple deletion retains the row and its active provider",
          arguments: AppleFoundationModel.allCases)
    func failedAppleDeletionKeepsConfigurationAndProvider(model: AppleFoundationModel) async throws {
        let rows = makeAppleModelRecords()
        let repository = StubModelRepository(rows: rows)
        repository.deleteError = ModelConfigurationRepositoryError.unknownModel(id: "synthetic-failure")
        let registry = LLMProviderRegistry()
        for row in rows {
            await registry.register(FakeLLMProvider(
                id: row.id, model: LLMModel(id: row.modelId, displayName: row.name)
            ))
        }
        let existing = try #require(rows.first { $0.modelId == model.rawValue })
        try await registry.setActive(id: existing.id)
        let vm = makeViewModel(modelRepository: repository, llmProviderRegistry: registry)

        let succeeded = await vm.deleteModel(id: existing.id)

        #expect(!succeeded)
        #expect(vm.modelEditError?.contains("Could not delete model") == true)
        #expect(repository.rows == rows)
        #expect(Set(vm.models.map(\.id)) == Set(rows.map(\.id)))
        #expect(await registry.allProviders().count == 2)
        #expect(await registry.activeID() == existing.id)
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

    // MARK: - loadAvailableModels (live model-list cache)

    @Test("A successful fetch reconciles ids against the catalog and caches them")
    func loadAvailableModelsSuccessReconciles() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5", "mystery-model"]))
        let vm = makeViewModel(modelListingService: service)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: false)

        let cached = vm.fetchedModels["openai"]
        #expect(cached?.map(\.id) == ["gpt-5.5", "mystery-model"])
        // Known id keeps curated metadata; unknown id gets defaults.
        #expect(cached?.first?.maxContextTokens == 1_000_000)
        #expect(cached?.last?.maxContextTokens == LLMProviderCatalog.defaultFetchedMaxContextTokens)
        #expect(vm.modelListNote["openai"] == nil)
        #expect(vm.loadingModelsProviderID == nil)
        #expect(await service.callCount == 1)
        // The entered key is passed through (trimmed) to the service.
        #expect(await service.lastAPIKey == "sk-test")
    }

    @Test("A cache hit avoids a second network call unless forced")
    func loadAvailableModelsCacheHit() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let vm = makeViewModel(modelListingService: service)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: false)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: false)
        #expect(await service.callCount == 1)
    }

    @Test("force re-fetches even when the cache is populated")
    func loadAvailableModelsForceRefetches() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let vm = makeViewModel(modelListingService: service)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: false)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: true)
        #expect(await service.callCount == 2)
    }

    @Test("A forced re-fetch after a key correction passes the NEW key to the service")
    func loadAvailableModelsForcedRefetchUsesNewKey() async {
        // The cache is keyed by provider only, so the pane's key-typed
        // debounce forces — and the corrected key must reach the wire,
        // not the one that populated the cache.
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let vm = makeViewModel(modelListingService: service)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-first", force: false)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-corrected", force: true)
        #expect(await service.callCount == 2)
        #expect(await service.lastAPIKey == "sk-corrected")
    }

    @Test("An empty/nil key short-circuits without a network call (catalog fallback)")
    func loadAvailableModelsEmptyKeyNoCall() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let vm = makeViewModel(modelListingService: service)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "   ", force: false)
        await vm.loadAvailableModels(providerID: "openai", apiKey: nil, force: true)
        #expect(await service.callCount == 0)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == nil)
    }

    @Test("A failure records the fallback note and leaves the cache empty")
    func loadAvailableModelsFailureSetsNote() async {
        let service = ScriptedModelListingService(.failure(.transport("HTTP 401")))
        let vm = makeViewModel(modelListingService: service)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-bad", force: false)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == SettingsViewModel.modelListFallbackNote)
        #expect(vm.loadingModelsProviderID == nil)
    }

    @Test("An empty result is a soft failure — note set, cache left empty")
    func loadAvailableModelsEmptyResultSetsNote() async {
        let service = ScriptedModelListingService(.ids([]))
        let vm = makeViewModel(modelListingService: service)
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: false)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == SettingsViewModel.modelListFallbackNote)
    }

    @Test("A forced refresh that fails clears the prior cached list (note stays truthful)")
    func loadAvailableModelsForcedFailureClearsStaleCache() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5", "mystery-model"]))
        let vm = makeViewModel(modelListingService: service)
        // First fetch succeeds and caches a live list (incl. a non-catalog id).
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: false)
        #expect(vm.fetchedModels["openai"]?.map(\.id) == ["gpt-5.5", "mystery-model"])
        // A forced refresh now fails — the stale list must be dropped so the
        // dropdown falls back to the catalog and the note isn't a lie.
        await service.setOutcome(.failure(.transport("HTTP 500")))
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: true)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == SettingsViewModel.modelListFallbackNote)
    }

    @Test("A cancelled fetch leaves the cache and note untouched (debounce restart is not a failure)")
    func loadAvailableModelsCancellationIsNotFailure() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let vm = makeViewModel(modelListingService: service)
        // Populate a good cache first, then cancel a forced re-fetch
        // mid-flight — the pane's `.task(id: apiKey)` does exactly this on
        // every keystroke. The cancelled fetch must not wipe the cache or
        // post the fallback note; the restarted fetch owns the next state.
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-test", force: false)
        await service.setOutcome(.hang)
        let inFlight = Task { await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-corrected", force: true) }
        inFlight.cancel()
        await inFlight.value
        #expect(vm.fetchedModels["openai"]?.map(\.id) == ["gpt-5.5"])
        #expect(vm.modelListNote["openai"] == nil)
        #expect(vm.loadingModelsProviderID == nil)
    }

    @Test("Providers with no list endpoint (Custom, Apple) never call the service")
    func loadAvailableModelsNonListableProvidersNoCall() async {
        let service = ScriptedModelListingService(.ids(["x"]))
        let vm = makeViewModel(modelListingService: service)
        // Custom has no defaultBaseURL; Apple's kind has no list endpoint.
        await vm.loadAvailableModels(providerID: LLMProviderCatalog.customProviderID, apiKey: "sk", force: true)
        await vm.loadAvailableModels(providerID: LLMProviderCatalog.appleProviderID, apiKey: "sk", force: true)
        #expect(await service.callCount == 0)
    }

    // MARK: - loadAvailableModelsUsingStoredKey (edit-mode fetch)

    /// Editing row used by the stored-key fetch tests: a built-in OpenAI
    /// row whose key lives in the Keychain under `ref-1`.
    private static func storedKeyRow(apiKeyRef: String? = "ref-1") -> ModelConfigurationRecord {
        .init(
            id: "row-1",
            name: "GPT 5.5",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKeyRef: apiKeyRef,
            modelId: "gpt-5.5",
            createdAt: Date(),
            supportsThinking: true,
            maxContextTokens: 400_000,
            isSelected: false
        )
    }

    @Test("Resolves the row's Keychain key and fetches with it")
    func storedKeyFetchResolvesKeychainKeyAndFetches() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let modelRepo = StubModelRepository(rows: [Self.storedKeyRow()])
        modelRepo.storedKeys["ref-1"] = "sk-stored"
        let vm = makeViewModel(modelRepository: modelRepo, modelListingService: service)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: false)

        #expect(await service.callCount == 1)
        #expect(await service.lastAPIKey == "sk-stored")
        #expect(vm.fetchedModels["openai"]?.map(\.id) == ["gpt-5.5"])
        #expect(vm.modelListNote["openai"] == nil)
    }

    @Test("A row without an apiKeyRef is a silent no-op (catalog fallback, no note)")
    func storedKeyFetchNoRefIsSilent() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let modelRepo = StubModelRepository(rows: [Self.storedKeyRow(apiKeyRef: nil)])
        let vm = makeViewModel(modelRepository: modelRepo, modelListingService: service)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: false)

        #expect(await service.callCount == 0)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == nil)
    }

    @Test("A Keychain miss (ref present, no stored key) is a silent no-op")
    func storedKeyFetchKeychainMissIsSilent() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let modelRepo = StubModelRepository(rows: [Self.storedKeyRow()])
        // ref-1 intentionally absent from storedKeys.
        let vm = makeViewModel(modelRepository: modelRepo, modelListingService: service)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: false)

        #expect(await service.callCount == 0)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == nil)
    }

    @Test("An unknown row id is a silent no-op")
    func storedKeyFetchUnknownRowIsSilent() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let modelRepo = StubModelRepository(rows: [])
        let vm = makeViewModel(modelRepository: modelRepo, modelListingService: service)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "missing", force: false)

        #expect(await service.callCount == 0)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == nil)
    }

    @Test("A fetch failure with a resolved key posts the fallback note (delegate behavior)")
    func storedKeyFetchFailureSetsFallbackNote() async {
        let service = ScriptedModelListingService(.failure(.transport("HTTP 401")))
        let modelRepo = StubModelRepository(rows: [Self.storedKeyRow()])
        modelRepo.storedKeys["ref-1"] = "sk-revoked"
        let vm = makeViewModel(modelRepository: modelRepo, modelListingService: service)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: false)

        #expect(await service.callCount == 1)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == SettingsViewModel.modelListFallbackNote)
    }

    @Test("A cache hit skips the Keychain round-trip and network unless forced")
    func storedKeyFetchCacheHitSkipsKeychainAndNetworkUnlessForced() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let modelRepo = StubModelRepository(rows: [Self.storedKeyRow()])
        modelRepo.storedKeys["ref-1"] = "sk-stored"
        let vm = makeViewModel(modelRepository: modelRepo, modelListingService: service)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: false)
        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: false)
        #expect(await service.callCount == 1)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: true)
        #expect(await service.callCount == 2)
    }

    @Test("A FORCED stored-key fetch with no resolvable key posts the fallback note (refresh isn't a dead button)")
    func storedKeyForcedFetchWithoutKeyPostsNote() async {
        let service = ScriptedModelListingService(.ids(["gpt-5.5"]))
        let modelRepo = StubModelRepository(rows: [Self.storedKeyRow()])
        // ref-1 intentionally absent from storedKeys (lost Keychain entry).
        let vm = makeViewModel(modelRepository: modelRepo, modelListingService: service)

        await vm.loadAvailableModelsUsingStoredKey(providerID: "openai", editingModelID: "row-1", force: true)

        #expect(await service.callCount == 0)
        #expect(vm.fetchedModels["openai"] == nil)
        #expect(vm.modelListNote["openai"] == SettingsViewModel.modelListFallbackNote)
    }

    @Test("A stale fetch completing after a newer one discards its writes (generation guard)")
    func staleFetchCompletionIsDiscarded() async {
        // The edit pane's stored-key appear-fetch can still be on the wire
        // when the typed-key debounce fetch starts and finishes. The slow
        // (stale) completion must not clobber the fresh list — neither its
        // success result nor a failure's cache-wipe + fallback note.
        let service = ScriptedModelListingService(.gated(["stale-model"]))
        let vm = makeViewModel(modelListingService: service)

        let staleTask = Task {
            await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-old", force: false)
        }
        // Entry signal: the stale fetch is suspended at the gate, inside
        // the network call, BEFORE the newer fetch starts.
        await service.awaitGateEntered()

        await service.setOutcome(.ids(["gpt-5.5"]))
        await vm.loadAvailableModels(providerID: "openai", apiKey: "sk-new", force: true)
        #expect(vm.fetchedModels["openai"]?.map(\.id) == ["gpt-5.5"])

        // Let the stale fetch finish; its (different) result must be dropped.
        await service.releaseGate()
        await staleTask.value
        #expect(vm.fetchedModels["openai"]?.map(\.id) == ["gpt-5.5"])
        #expect(vm.modelListNote["openai"] == nil)
    }

    private func makeViewModel(
        settingRepository: any SettingRepository = InMemorySettingRepository(),
        modelRepository: any ModelConfigurationRepository = StubModelRepository(rows: []),
        conversationRepository: any ConversationRepository = StubConversationRepository(rows: []),
        toolRegistry: ToolRegistry = ToolRegistry(),
        userPersonalizationReceiver: any UserPersonalizationReceiver = FakeUserPersonalizationReceiver(),
        autoCompactPolicyReceiver: any AutoCompactPolicyReceiver = FakeAutoCompactPolicyReceiver(),
        webSearchPolicyReceiver: any WebSearchPolicyReceiver = FakeWebSearchPolicyReceiver(),
        hapticsEngine: any HapticsEngine = NoOpHapticsEngine(),
        memoryRepository: (any MemoryRepository)? = nil,
        llmProviderRegistry: LLMProviderRegistry? = nil,
        httpClient: (any HTTPClient)? = nil,
        modelListingService: (any ModelListingService)? = nil,
        appleFoundationAvailability: AppleFoundationAvailability = .unavailable(.deviceNotEligible),
        appleFoundationContextTokens: Int = 4_096,
        appleFoundationStatusProvider: (any AppleFoundationModelStatusProvider)? = nil,
        clock: any Clock = FixedClock(Date(timeIntervalSince1970: 0))
    ) -> SettingsViewModel {
        // The availability default is *deliberately* a fixed unavailable
        // case rather than the SDK's `SystemLanguageModel.default
        // .availability` so unit tests don't pick up whatever AFM state
        // happens to be on the host running them. Tests that need to
        // exercise the AFM-available code path should pass
        // `appleFoundationAvailability: .available` explicitly.
        SettingsViewModel(
            appInfo: Self.appInfo,
            settingRepository: settingRepository,
            modelRepository: modelRepository,
            conversationRepository: conversationRepository,
            toolRegistry: toolRegistry,
            userPersonalizationReceiver: userPersonalizationReceiver,
            autoCompactPolicyReceiver: autoCompactPolicyReceiver,
            webSearchPolicyReceiver: webSearchPolicyReceiver,
            hapticsEngine: hapticsEngine,
            clock: clock,
            memoryRepository: memoryRepository,
            llmProviderRegistry: llmProviderRegistry,
            httpClient: httpClient,
            modelListingService: modelListingService,
            appleFoundationAvailability: appleFoundationAvailability,
            appleFoundationContextTokens: appleFoundationContextTokens,
            appleFoundationStatusProvider: appleFoundationStatusProvider
        )
    }

    private func makeAppleModelRecords() -> [ModelConfigurationRecord] {
        AppleFoundationModel.allCases.map { model in
            ModelConfigurationRecord(
                id: "apple-\(model.rawValue)", name: model.displayName, baseURL: nil, apiKeyRef: nil,
                modelId: model.rawValue, createdAt: Date(timeIntervalSince1970: 700),
                kind: .appleFoundation, maxContextTokens: model.fallbackContextTokens
            )
        }
    }

    private func makeAppleStatusProvider(
        localAvailability: AppleFoundationAvailability = .available,
        cloudAvailability: AppleFoundationModelStatus.Availability = .available,
        cloudQuota: AppleFoundationModelStatus.QuotaUsage? = nil,
        supportsPrivateCloudCompute: Bool = true
    ) -> FixedAppleFoundationModelStatusProvider {
        FixedAppleFoundationModelStatusProvider(
            localAvailability: localAvailability,
            supportsPrivateCloudCompute: supportsPrivateCloudCompute,
            privateCloudComputeStatus: AppleFoundationModelStatus(
                model: .privateCloudCompute, availability: cloudAvailability,
                contextTokens: 24_000, quota: cloudQuota
            ),
            localContextTokens: 8_192
        )
    }
}

// MARK: - Test doubles

/// Mutable Apple readiness with an awaitable first-request gate; never consults the OS.
private actor ScriptedAppleFoundationStatusProvider: AppleFoundationModelStatusProvider {
    nonisolated let supportsPrivateCloudCompute = true
    private var cloudStatus: AppleFoundationModelStatus
    private var requests: [AppleFoundationModel] = []
    private var gateFirstRequest: Bool
    private var gateEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiter: CheckedContinuation<Void, Never>?

    init(cloudStatus: AppleFoundationModelStatus, gateFirstRequest: Bool = false) {
        self.cloudStatus = cloudStatus
        self.gateFirstRequest = gateFirstRequest
    }

    func setCloudStatus(_ status: AppleFoundationModelStatus) {
        precondition(status.model == .privateCloudCompute)
        cloudStatus = status
    }

    func requestedModels() -> [AppleFoundationModel] { requests }

    func waitUntilGateEntered() async {
        if gateEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseGate() {
        guard let gateWaiter else { preconditionFailure("No Apple status request is waiting") }
        self.gateWaiter = nil
        gateWaiter.resume()
    }

    func status(for model: AppleFoundationModel) async -> AppleFoundationModelStatus {
        requests.append(model)
        if gateFirstRequest {
            gateFirstRequest = false
            await withCheckedContinuation { continuation in
                gateWaiter = continuation
                gateEntered = true
                let waiters = entryWaiters
                entryWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        switch model {
        case .local:
            return AppleFoundationModelStatus(model: model, availability: .available, contextTokens: 8_192)
        case .privateCloudCompute:
            return cloudStatus
        }
    }
}

private actor InMemorySettingRepository: SettingRepository {
    private var storage: [String: String] = [:]

    func get(_ key: String) async throws -> String? { storage[key] }
    func set(_ key: String, value: String) async throws { storage[key] = value }
    func delete(_ key: String) async throws { storage.removeValue(forKey: key) }
    func all() async throws -> [String: String] { storage }
}

/// Scripted `ModelListingService` double for `loadAvailableModels` tests.
/// Returns a fixed outcome and records the call count + last key so a test
/// can assert the cache/short-circuit/refresh logic without any network. An
/// actor so the cross-`await` counter is race-free.
private actor ScriptedModelListingService: ModelListingService {
    enum Outcome {
        case ids([String])
        case failure(ModelListingError)
        /// Sleeps until the surrounding task is cancelled — drives the
        /// cancelled-fetch path (the pane's debounce restarting mid-flight).
        case hang
        /// Suspends at a gate until `releaseGate()` is called, then returns
        /// the ids — drives the stale-completion path (a slow fetch landing
        /// after a newer one already wrote the cache). The test sequences
        /// the race deterministically: `awaitGateEntered()` is the entry
        /// signal (AGENTS.md §Testing.7 "staged concurrency"), then the
        /// newer fetch runs to completion, then `releaseGate()` lets the
        /// stale one finish.
        case gated([String])
    }

    private var outcome: Outcome
    private(set) var callCount = 0
    private(set) var lastAPIKey: String?
    private var gateEntered = false
    private var gateEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ outcome: Outcome) { self.outcome = outcome }

    /// Swap the scripted outcome between calls (e.g. success then failure on
    /// a forced refresh).
    func setOutcome(_ outcome: Outcome) { self.outcome = outcome }

    /// Suspends until a `.gated` call has reached the gate. Returns
    /// immediately if it already has.
    func awaitGateEntered() async {
        if gateEntered { return }
        await withCheckedContinuation { gateEnteredWaiters.append($0) }
    }

    /// Releases every call suspended at the `.gated` gate.
    func releaseGate() {
        let waiters = gateWaiters
        gateWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func listModelIDs(kind: LLMProviderKind, baseURL: URL, apiKey: String?) async throws -> [String] {
        callCount += 1
        lastAPIKey = apiKey
        switch outcome {
        case let .ids(ids): return ids
        case let .failure(error): throw error
        case .hang:
            try await Task.sleep(for: .seconds(30))
            return []
        case let .gated(ids):
            gateEntered = true
            let enteredWaiters = gateEnteredWaiters
            gateEnteredWaiters = []
            for waiter in enteredWaiters { waiter.resume() }
            await withCheckedContinuation { gateWaiters.append($0) }
            return ids
        }
    }
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
    /// Drives delete failures without changing persistence or registered-provider state.
    var deleteError: Error?

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
        // Mirror production's `buildableKindRequest` empty-check: "empty"
        // means no row this binary can build a provider for, so a table
        // holding only native-kind rows still seeds (keeps the user a
        // recoverable model). A plain `rows.isEmpty` would diverge.
        guard !rows.contains(where: { $0.kind.hasProviderAdapter }) else { return nil }
        let record = make()
        // Mirror `demoteUnselectableSelections`: free the selection slot from
        // any non-buildable selected row before inserting a selected seed.
        if record.isSelected {
            rows = rows.map {
                guard $0.isSelected, !$0.kind.hasProviderAdapter else { return $0 }
                var copy = $0
                copy.isSelected = false
                return copy
            }
        }
        rows.append(record)
        return record
    }
    func delete(id: String) async throws {
        if let error = deleteError { throw error }
        rows.removeAll { $0.id == id }
        storedKeys[id] = nil
    }
    func setSelected(id: String) async throws {
        // Mirror production's guard: refuse to select a row the binary can't
        // build a provider for, so a test exercising this path validates
        // against the same contract as `GRDBModelConfigurationRepository`.
        guard let row = rows.first(where: { $0.id == id }) else {
            throw ModelConfigurationRepositoryError.unknownModel(id: id)
        }
        guard row.kind.hasProviderAdapter else {
            throw ModelConfigurationRepositoryError.unselectableKind(
                id: id, kind: row.kind.rawValue
            )
        }
        rows = rows.map {
            var copy = $0
            copy.isSelected = ($0.id == id)
            return copy
        }
    }
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
