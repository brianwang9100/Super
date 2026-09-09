import Core
import Foundation
import Testing
@testable import Chat

@Suite("ChatSettings")
struct ChatSettingsTests {
    @Test("default userPersonalization is empty")
    func defaultUserPersonalizationIsEmpty() {
        #expect(ChatSettings.default.userPersonalization.isEmpty)
    }

    @Test("compaction threshold constants are the single source of truth")
    func compactionThresholdConstantsAreConsistent() {
        #expect(ChatSettings.defaultAutoCompactThreshold == 0.85)
        #expect(ChatSettings.default.autoCompactThreshold == ChatSettings.defaultAutoCompactThreshold)
        #expect(ChatSettings.defaultManualCompactMinThreshold == 0.30)
    }
}

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
        // Use the production bundle seam; Bundle.module here refers to the test bundle.
        let legacyDefault = ChatSettingsStore.legacyDefaultSystemPrompt
        // The bundled snapshot distinguishes untouched defaults from custom legacy text.
        #expect(!legacyDefault.isEmpty)
        try await repo.set(ChatSettingsStore.Keys.legacySystemPrompt, value: legacyDefault)

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.userPersonalization.isEmpty)
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

    @Test("summarizeTitlesEnabled defaults to true; titleModelId nil when unset")
    func titleSettingsDefaults() async {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()
        #expect(settings.summarizeTitlesEnabled == true)
        #expect(settings.titleModelId == nil)
        #expect(await store.isTitleSummarizationEnabled() == true)
        #expect(await store.titleModelId() == nil)
    }

    @Test("title summarization settings round-trip through load and the focused getters")
    func titleSettingsRoundTrip() async throws {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        try await store.setSummarizeTitlesEnabled(false)
        try await store.setTitleModelId("system-default")

        let settings = await store.load()
        #expect(settings.summarizeTitlesEnabled == false)
        #expect(settings.titleModelId == "system-default")
        #expect(await store.isTitleSummarizationEnabled() == false)
        #expect(await store.titleModelId() == "system-default")
    }

    @Test("setTitleModelId(nil) deletes the row, restoring the automatic default")
    func titleModelIdClearsToAutomatic() async throws {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        try await store.setTitleModelId("gpt-4o")
        #expect(await store.titleModelId() == "gpt-4o")

        try await store.setTitleModelId(nil)
        #expect(await store.titleModelId() == nil)
        #expect(try await repo.get(ChatSettingsStore.Keys.titleModelId) == nil)
    }

    @Test("set* round-trips do not disturb other persisted fields")
    func roundTripIndependence() async throws {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)

        try await store.setTheme(.vellumDark)
        try await store.setTypography(.system)
        try await store.setUserPersonalization("custom")
        try await store.setDefaultVerbosity(.verbose)
        try await store.setFontScale(1.10)
        try await store.setAutoCompactEnabled(false)
        try await store.setAutoCompactThreshold(0.75)
        try await store.setLastSelectedModelId("gpt-4o")
        try await store.setAskBeforeSearching(false)
        try await store.setSummarizeTitlesEnabled(false)
        try await store.setTitleModelId("system-default")

        let settings = await store.load()
        #expect(settings.themeId == .vellumDark)
        #expect(settings.typographyID == .system)
        #expect(settings.userPersonalization == "custom")
        #expect(settings.defaultVerbosity == .verbose)
        #expect(settings.fontScale == 1.10)
        #expect(settings.autoCompactEnabled == false)
        #expect(settings.autoCompactThreshold == 0.75)
        #expect(settings.lastSelectedModelId == "gpt-4o")
        #expect(settings.askBeforeSearching == false)
        #expect(settings.summarizeTitlesEnabled == false)
        #expect(settings.titleModelId == "system-default")
    }
}

@Suite("ChatSettingsStore theme migration")
struct ChatSettingsStoreThemeMigrationTests {
    @Test("legacy three-theme strings map onto the new variants")
    func legacyStringsMigrate() {
        #expect(ChatSettingsStore.migrateThemeID("light") == .vellumLight)
        #expect(ChatSettingsStore.migrateThemeID("dark") == .vellumDark)
        #expect(ChatSettingsStore.migrateThemeID("sepia") == .vellumLight)
    }

    @Test("the retired Sepia family folds onto Vellum, preserving mode")
    func retiredSepiaMigrates() {
        #expect(ChatSettingsStore.migrateThemeID("sepiaLight") == .vellumLight)
        #expect(ChatSettingsStore.migrateThemeID("sepiaDark") == .vellumDark)
    }

    @Test("a current variant string decodes unchanged")
    func currentStringsRoundTrip() {
        for id in ChatSettings.ThemeID.allCases {
            #expect(ChatSettingsStore.migrateThemeID(id.rawValue) == id)
        }
    }

    @Test("absent or unrecognized values fall back to the Vellum Light default")
    func unknownFallsBackToDefault() {
        #expect(ChatSettingsStore.migrateThemeID(nil) == .vellumLight)
        #expect(ChatSettingsStore.migrateThemeID("emerald") == .vellumLight)
        #expect(ChatSettings.default.themeId == .vellumLight)
    }

    @Test("load() migrates a persisted legacy theme string end-to-end")
    func loadMigratesLegacyTheme() async throws {
        let repo = InMemorySettingRepository()
        try await repo.set(ChatSettingsStore.Keys.themeId, value: "sepia")

        let store = ChatSettingsStore(repository: repo)
        let settings = await store.load()

        #expect(settings.themeId == .vellumLight)
    }
}

private actor InMemorySettingRepository: SettingRepository {
    private var storage: [String: String] = [:]

    func get(_ key: String) async throws -> String? { storage[key] }
    func set(_ key: String, value: String) async throws { storage[key] = value }
    func delete(_ key: String) async throws { storage.removeValue(forKey: key) }
    func all() async throws -> [String: String] { storage }
}
