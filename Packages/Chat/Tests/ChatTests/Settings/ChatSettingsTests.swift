import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `ChatSettings.default` and `ChatSettingsStore`'s
/// missing-key fallback / legacy-`systemPrompt` migration. The
/// authoritative chat-assistant prompt is no longer a user-facing
/// setting; `ChatSettings.userPersonalization` is a free-form "about
/// me" field that defaults to empty.
@Suite("ChatSettings")
struct ChatSettingsTests {
    @Test("default userPersonalization is empty")
    func defaultUserPersonalizationIsEmpty() {
        #expect(ChatSettings.default.userPersonalization.isEmpty)
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
/// missing-key-fallback contract plus the one-shot legacy-`systemPrompt`
/// migration.
@Suite("ChatSettingsStore")
struct ChatSettingsStoreTests {
    @Test("load returns an empty userPersonalization when no row is stored")
    func loadFallsBackToEmptyWhenUnset() async {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()
        #expect(settings.userPersonalization.isEmpty)
    }

    @Test("load returns the stored userPersonalization verbatim")
    func loadWithStoredPersonalizationReturnsStoredValue() async throws {
        let repo = InMemorySettingRepository()
        let custom = "I prefer terse, no-emoji answers."
        try await repo.set(ChatSettingsStore.Keys.userPersonalization, value: custom)

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.userPersonalization == custom)
    }

    @Test("migration: legacy systemPrompt equal to the snapshot is cleared silently")
    func migrationClearsLegacyDefaultPrompt() async throws {
        let repo = InMemorySettingRepository()
        // Seed the previous build's stored value — a verbatim copy of the
        // bundled `LegacyDefaultSystemPromptV1.md` snapshot. We read it
        // through the production code's seam (rather than calling
        // `AppletSystemPrompt.load(from: .module, ...)` directly) because
        // `.module` here would resolve to the test bundle — the snapshot
        // file lives in the Chat target's bundle.
        let legacyDefault = ChatSettingsStore.legacyDefaultSystemPrompt
        // Sanity check the snapshot is bundled; if not, the migration
        // can't disambiguate "user never customized" from "user wrote the
        // exact default verbatim".
        #expect(!legacyDefault.isEmpty)
        try await repo.set(ChatSettingsStore.Keys.legacySystemPrompt, value: legacyDefault)

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.userPersonalization.isEmpty)
        // Legacy row deleted so the migration doesn't re-run.
        let legacyAfter = try await repo.get(ChatSettingsStore.Keys.legacySystemPrompt)
        #expect(legacyAfter == nil)
    }

    @Test("migration: custom legacy systemPrompt carries forward as personalization")
    func migrationCarriesCustomPromptForward() async throws {
        let repo = InMemorySettingRepository()
        let custom = "Always answer in haiku."
        try await repo.set(ChatSettingsStore.Keys.legacySystemPrompt, value: custom)

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.userPersonalization == custom)
        // Legacy row removed, new key written.
        let legacyAfter = try await repo.get(ChatSettingsStore.Keys.legacySystemPrompt)
        let newAfter = try await repo.get(ChatSettingsStore.Keys.userPersonalization)
        #expect(legacyAfter == nil)
        #expect(newAfter == custom)
    }

    @Test("migration: new userPersonalization wins and clears any straggler legacy row")
    func migrationCleansLegacyKeyWhenNewKeyAlreadyWritten() async throws {
        let repo = InMemorySettingRepository()
        let neu = "I am vegetarian."
        let legacy = "Always answer in haiku."
        try await repo.set(ChatSettingsStore.Keys.userPersonalization, value: neu)
        try await repo.set(ChatSettingsStore.Keys.legacySystemPrompt, value: legacy)

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.userPersonalization == neu)
        // Idempotency: the early-return path also deletes the legacy
        // row so it can't linger across launches.
        let legacyAfter = try await repo.get(ChatSettingsStore.Keys.legacySystemPrompt)
        #expect(legacyAfter == nil)
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

    @Test("askBeforeSearching defaults to true when no row is stored")
    func askBeforeSearchingDefaultsTrue() async {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()
        #expect(settings.askBeforeSearching == true)
    }

    @Test("setAskBeforeSearching round-trips through load")
    func askBeforeSearchingRoundTrip() async throws {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        try await store.setAskBeforeSearching(false)
        let settings = await store.load()
        #expect(settings.askBeforeSearching == false)
    }

    @Test("set* round-trips do not disturb other persisted fields")
    func roundTripIndependence() async throws {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)

        try await store.setTheme(.dark)
        try await store.setTypography(.system)
        try await store.setUserPersonalization("custom")
        try await store.setDefaultVerbosity(.verbose)
        try await store.setFontScale(1.10)
        try await store.setAutoCompactEnabled(false)
        try await store.setAutoCompactThreshold(0.75)
        try await store.setLastSelectedModelId("gpt-4o")
        try await store.setAskBeforeSearching(false)

        let settings = await store.load()
        #expect(settings.themeId == .dark)
        #expect(settings.typographyID == .system)
        #expect(settings.userPersonalization == "custom")
        #expect(settings.defaultVerbosity == .verbose)
        #expect(settings.fontScale == 1.10)
        #expect(settings.autoCompactEnabled == false)
        #expect(settings.autoCompactThreshold == 0.75)
        #expect(settings.lastSelectedModelId == "gpt-4o")
        #expect(settings.askBeforeSearching == false)
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
