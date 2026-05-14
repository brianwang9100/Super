import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `ChatSettings.default` and `ChatSettingsStore`'s missing-key
/// fallback. The non-overriding-of-user-customization guarantee is
/// covered by `loadWithStoredPromptReturnsStoredValueNotDefault` below
/// (direct store test) plus `SettingsViewModelTests.loadPersistedValues`
/// (indirect, through the view model).
@Suite("ChatSettings")
struct ChatSettingsTests {
    @Test("default systemPrompt matches an independent read of the bundled file")
    func defaultSystemPromptMatchesBundledFile() {
        let onDisk = ChatSettings._loadBundledDefaultSystemPrompt()
        // The cached default must equal a fresh read of the bundled
        // markdown. Silent revert to a hardcoded literal would diverge
        // these two strings; an empty / missing bundle would fatalError
        // before the test ran.
        #expect(ChatSettings.default.systemPrompt == onDisk)
        #expect(!onDisk.isEmpty)
    }

    @Test("default systemPrompt is trimmed of surrounding whitespace")
    func defaultSystemPromptIsTrimmed() {
        let prompt = ChatSettings.default.systemPrompt
        #expect(prompt == prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("compaction threshold constants are the single source of truth")
    func compactionThresholdConstantsAreConsistent() {
        // Regression test for the 0.75/0.85 drift that shipped before: the
        // user-facing `default` must reference the named constant, and the
        // constant itself is what the orchestration-layer fallbacks pin
        // to. If anyone re-introduces a literal anywhere, this test fails
        // when they update one but not the other.
        #expect(ChatSettings.defaultAutoCompactThreshold == 0.85)
        #expect(ChatSettings.default.autoCompactThreshold == ChatSettings.defaultAutoCompactThreshold)
        #expect(ChatSettings.defaultManualCompactMinThreshold == 0.30)
    }
}

/// Direct tests for `ChatSettingsStore.load()` covering the
/// missing-key-fallback contract — the architectural guarantee that
/// changing `ChatSettings.default.systemPrompt` (e.g. by editing the
/// bundled markdown) cannot override a value the user has already saved.
@Suite("ChatSettingsStore")
struct ChatSettingsStoreTests {
    @Test("load returns the bundled default when no systemPrompt row is stored")
    func loadFallsBackToDefaultWhenUnset() async {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()
        #expect(settings.systemPrompt == ChatSettings.default.systemPrompt)
    }

    @Test("load returns the stored prompt verbatim, not the default")
    func loadWithStoredPromptReturnsStoredValueNotDefault() async throws {
        let repo = InMemorySettingRepository()
        let userPrompt = "My custom prompt — do not touch."
        try await repo.set(ChatSettingsStore.Keys.systemPrompt, value: userPrompt)

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.systemPrompt == userPrompt)
        #expect(settings.systemPrompt != ChatSettings.default.systemPrompt)
    }

    @Test("lastSelectedModelId is nil when no row is stored")
    func lastSelectedModelIdMissingByDefault() async {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()
        #expect(settings.lastSelectedModelId == nil)
    }

    @Test("setLastSelectedModelId round-trips through load")
    func lastSelectedModelIdRoundTrip() async throws {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        try await store.setLastSelectedModelId("claude-opus-4-7")
        let settings = await store.load()
        #expect(settings.lastSelectedModelId == "claude-opus-4-7")
    }

    @Test("setLastSelectedModelId does not disturb other persisted fields")
    func lastSelectedModelIdIndependentOfOtherKeys() async throws {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)

        try await store.setTheme(.dark)
        try await store.setSystemPrompt("custom")
        try await store.setDefaultVerbosity(.verbose)
        try await store.setFontScale(1.10)
        try await store.setAutoCompactEnabled(false)
        try await store.setAutoCompactThreshold(0.75)
        try await store.setLastSelectedModelId("gpt-4o")

        let settings = await store.load()
        #expect(settings.themeId == .dark)
        #expect(settings.systemPrompt == "custom")
        #expect(settings.defaultVerbosity == .verbose)
        #expect(settings.fontScale == 1.10)
        #expect(settings.autoCompactEnabled == false)
        #expect(settings.autoCompactThreshold == 0.75)
        #expect(settings.lastSelectedModelId == "gpt-4o")
    }
}

/// In-memory `SettingRepository` for tests that exercise the store
/// without touching SQLite. Duplicated from `SettingsViewModelTests` —
/// extract to a shared helper if a third caller appears.
private actor InMemorySettingRepository: SettingRepository {
    private var storage: [String: String] = [:]

    func get(_ key: String) async throws -> String? { storage[key] }
    func set(_ key: String, value: String) async throws { storage[key] = value }
    func delete(_ key: String) async throws { storage.removeValue(forKey: key) }
    func all() async throws -> [String: String] { storage }
}
