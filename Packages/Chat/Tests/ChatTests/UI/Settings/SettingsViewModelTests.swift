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
        try? await settingRepo.set(ChatSettingsStore.Keys.systemPrompt, value: "Hello")
        try? await settingRepo.set(ChatSettingsStore.Keys.defaultVerbosity, value: "thinking")
        try? await settingRepo.set(ChatSettingsStore.Keys.fontScale, value: "1.1")
        try? await settingRepo.set(ChatSettingsStore.Keys.autoCompactEnabled, value: "false")
        try? await settingRepo.set(ChatSettingsStore.Keys.autoCompactThreshold, value: "0.7")

        let vm = makeViewModel(settingRepository: settingRepo)
        await vm.load()
        #expect(vm.settings.themeId == .dark)
        #expect(vm.settings.systemPrompt == "Hello")
        #expect(vm.settings.defaultVerbosity == .thinking)
        #expect(vm.settings.fontScale == 1.1)
        #expect(vm.settings.autoCompactEnabled == false)
        #expect(vm.settings.autoCompactThreshold == 0.7)
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

    @Test("setSystemPrompt persists immediately")
    func setSystemPromptPersists() async {
        let settingRepo = InMemorySettingRepository()
        let vm = makeViewModel(settingRepository: settingRepo)
        await vm.setSystemPrompt("New prompt body.")
        let raw = try? await settingRepo.get(ChatSettingsStore.Keys.systemPrompt)
        #expect(raw == "New prompt body.")
    }

    @Test("setSystemPrompt forwards to the systemPromptReceiver")
    func setSystemPromptForwardsToReceiver() async {
        // The fan-out hop (`systemPromptReceiver?.setSystemPrompt(value)`)
        // is what propagates a Settings edit to active `ChatSession`s in
        // production. Without this assertion, a future refactor that drops
        // the forwarding line would compile, persist correctly, and leave
        // every running conversation stuck on the old prompt until app
        // restart — exactly the gap this PR exists to close.
        let receiver = FakeSystemPromptReceiver()
        let vm = makeViewModel(systemPromptReceiver: receiver)
        await vm.setSystemPrompt("Always reply in haiku.")
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
                supportsThinking: false,
                maxContextTokens: 8000,
                isSelected: true,
                createdAt: Date()
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
        vm.openPane(.theme)
        vm.openPane(.root)
        #expect(vm.navigationPath.isEmpty)
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
                supportsThinking: false,
                maxContextTokens: 64_000,
                isSelected: true,
                createdAt: Date()
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
                supportsThinking: false,
                maxContextTokens: 8_000,
                isSelected: false,
                createdAt: Date()
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

    @Test("deleteModel removes the row and refreshes the list")
    func deleteModelClears() async {
        let modelRepo = StubModelRepository(rows: [
            .init(
                id: "m1",
                name: "GPT",
                baseURL: URL(string: "https://x.example.com")!,
                apiKeyRef: "ref-1",
                modelId: "gpt",
                supportsThinking: false,
                maxContextTokens: 8_000,
                isSelected: false,
                createdAt: Date()
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

    // MARK: - Builders

    private func makeViewModel(
        settingRepository: any SettingRepository = InMemorySettingRepository(),
        modelRepository: any ModelConfigurationRepository = StubModelRepository(rows: []),
        conversationRepository: any ConversationRepository = StubConversationRepository(rows: []),
        toolRegistry: ToolRegistry = ToolRegistry(),
        systemPromptReceiver: any SystemPromptReceiver = FakeSystemPromptReceiver(),
        autoCompactPolicyReceiver: any AutoCompactPolicyReceiver = FakeAutoCompactPolicyReceiver()
    ) -> SettingsViewModel {
        SettingsViewModel(
            accountEmail: "test@example.com",
            appInfo: Self.appInfo,
            settingRepository: settingRepository,
            modelRepository: modelRepository,
            conversationRepository: conversationRepository,
            toolRegistry: toolRegistry,
            systemPromptReceiver: systemPromptReceiver,
            autoCompactPolicyReceiver: autoCompactPolicyReceiver
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

    init(rows: [ModelConfigurationRecord]) {
        self.rows = rows
    }

    func all() async throws -> [ModelConfigurationRecord] { rows }
    func fetch(id: String) async throws -> ModelConfigurationRecord? { rows.first { $0.id == id } }
    func selected() async throws -> ModelConfigurationRecord? { rows.first(where: \.isSelected) }
    func save(_ record: ModelConfigurationRecord) async throws {
        rows.removeAll { $0.id == record.id }
        rows.append(record)
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

private struct StaticExecutor: ToolExecutor {
    let toolID: String = "demo.tool"

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        ToolResult(toolID: toolID, content: "ok")
    }
}
