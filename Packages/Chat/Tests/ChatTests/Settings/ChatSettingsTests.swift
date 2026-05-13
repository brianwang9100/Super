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
    func loadWithStoredPromptReturnsStoredValueNotDefault() async {
        let repo = InMemorySettingRepository()
        let userPrompt = "My custom prompt — do not touch."
        try? await repo.set(ChatSettingsStore.Keys.systemPrompt, value: userPrompt)

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.systemPrompt == userPrompt)
        #expect(settings.systemPrompt != ChatSettings.default.systemPrompt)
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
