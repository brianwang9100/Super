import Core
import Foundation

/// Reads through on each load; callers own any cached projection.
public struct ChatSettingsStore: Sendable {
    private let repository: any SettingRepository

    public init(repository: any SettingRepository) {
        self.repository = repository
    }

    /// Missing, unrecognized, or unreadable settings use defaults.
    /// Migrate customized legacy system prompts to personalization, discarding the old bundled default.
    public func load() async -> ChatSettings {
        let raw = (try? await repository.all()) ?? [:]
        let personalization = await resolveUserPersonalization(raw: raw)
        return ChatSettings(
            themeId: Self.migrateThemeID(raw[Keys.themeId]),
            typographyID: raw[Keys.typographyID].flatMap(ChatSettings.TypographyID.init(rawValue:))
                ?? ChatSettings.default.typographyID,
            userPersonalization: personalization,
            defaultVerbosity: raw[Keys.defaultVerbosity].flatMap(ChatVerbosity.init(rawValue:))
                ?? ChatSettings.default.defaultVerbosity,
            fontScale: raw[Keys.fontScale].flatMap(Double.init)
                ?? ChatSettings.default.fontScale,
            autoCompactEnabled: raw[Keys.autoCompactEnabled].flatMap(Self.decodeBool)
                ?? ChatSettings.default.autoCompactEnabled,
            autoCompactThreshold: raw[Keys.autoCompactThreshold].flatMap(Double.init)
                ?? ChatSettings.default.autoCompactThreshold,
            lastSelectedModelId: raw[Keys.lastSelectedModelId],
            askBeforeSearching: raw[Keys.webSearchAskBeforeSearching].flatMap(Self.decodeBool)
                ?? ChatSettings.default.askBeforeSearching,
            summarizeTitlesEnabled: raw[Keys.summarizeTitles].flatMap(Self.decodeBool)
                ?? ChatSettings.default.summarizeTitlesEnabled,
            titleModelId: raw[Keys.titleModelId],
            hapticsEnabled: raw[Keys.hapticsEnabled].flatMap(Self.decodeBool)
                ?? ChatSettings.default.hapticsEnabled
        )
    }

    /// Migration writes and legacy cleanup are best-effort.
    private func resolveUserPersonalization(raw: [String: String]) async -> String {
        if let value = raw[Keys.userPersonalization] {
            // Clean up the legacy key even if both keys were stored.
            try? await repository.delete(Keys.legacySystemPrompt)
            return value
        }
        guard let legacy = raw[Keys.legacySystemPrompt] else {
            return ChatSettings.default.userPersonalization
        }
        let trimmedLegacy = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyDefault = Self.legacyDefaultSystemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLegacy == legacyDefault || trimmedLegacy.isEmpty {
            try? await repository.delete(Keys.legacySystemPrompt)
            return ChatSettings.default.userPersonalization
        }
        try? await repository.set(Keys.userPersonalization, value: legacy)
        try? await repository.delete(Keys.legacySystemPrompt)
        return legacy
    }

    /// Missing resources resolve to empty, preserving nonempty legacy text as personalization.
    /// Internal access lets tests read Chat's resource bundle rather than their own.
    static let legacyDefaultSystemPrompt: String = AppletSystemPrompt.load(
        from: .module,
        resource: "LegacyDefaultSystemPromptV1"
    )

    /// Map retired warm themes to Vellum; Lapis would change their color temperature.
    static func migrateThemeID(_ raw: String?) -> ChatSettings.ThemeID {
        guard let raw else { return ChatSettings.default.themeId }
        if let current = ChatSettings.ThemeID(rawValue: raw) { return current }
        switch raw {
        case "light", "sepia", "sepiaLight": return .vellumLight
        case "dark", "sepiaDark": return .vellumDark
        default: return ChatSettings.default.themeId
        }
    }

    public func setTheme(_ themeId: ChatSettings.ThemeID) async throws {
        try await repository.set(Keys.themeId, value: themeId.rawValue)
    }

    public func setTypography(_ typographyID: ChatSettings.TypographyID) async throws {
        try await repository.set(Keys.typographyID, value: typographyID.rawValue)
    }

    public func setUserPersonalization(_ value: String) async throws {
        try await repository.set(Keys.userPersonalization, value: value)
    }

    public func setDefaultVerbosity(_ value: ChatVerbosity) async throws {
        try await repository.set(Keys.defaultVerbosity, value: value.rawValue)
    }

    public func setFontScale(_ value: Double) async throws {
        try await repository.set(Keys.fontScale, value: String(ChatSettings.clampFontScale(value)))
    }

    public func setAutoCompactEnabled(_ value: Bool) async throws {
        try await repository.set(Keys.autoCompactEnabled, value: value ? "true" : "false")
    }

    public func setAutoCompactThreshold(_ value: Double) async throws {
        try await repository.set(Keys.autoCompactThreshold, value: String(ChatSettings.clampThreshold(value)))
    }

    public func setAskBeforeSearching(_ value: Bool) async throws {
        try await repository.set(Keys.webSearchAskBeforeSearching, value: value ? "true" : "false")
    }

    public func setSummarizeTitlesEnabled(_ value: Bool) async throws {
        try await repository.set(Keys.summarizeTitles, value: value ? "true" : "false")
    }

    public func setHapticsEnabled(_ value: Bool) async throws {
        try await repository.set(Keys.hapticsEnabled, value: value ? "true" : "false")
    }

    /// Persist the model record ID; nil restores automatic selection.
    /// A stale explicit ID disables titling rather than selecting AFM.
    public func setTitleModelId(_ id: String?) async throws {
        if let id {
            try await repository.set(Keys.titleModelId, value: id)
        } else {
            try await repository.delete(Keys.titleModelId)
        }
    }

    /// Avoid the full load and legacy migration on each title request.
    public func isTitleSummarizationEnabled() async -> Bool {
        guard let raw = try? await repository.get(Keys.summarizeTitles) else {
            return ChatSettings.default.summarizeTitlesEnabled
        }
        return Self.decodeBool(raw) ?? ChatSettings.default.summarizeTitlesEnabled
    }

    /// Nil selects AFM when available.
    public func titleModelId() async -> String? {
        try? await repository.get(Keys.titleModelId)
    }

    /// Persist the model record ID for new chats; a missing model falls back during resolution.
    public func setLastSelectedModelId(_ id: String) async throws {
        try await repository.set(Keys.lastSelectedModelId, value: id)
    }

    /// Nil uses the model registration default.
    public func isModelEnabled(id: String) async -> Bool? {
        guard let raw = try? await repository.get(Keys.modelEnabled(id: id)) else { return nil }
        return Self.decodeBool(raw)
    }

    public func setModelEnabled(id: String, enabled: Bool) async throws {
        try await repository.set(Keys.modelEnabled(id: id), value: enabled ? "true" : "false")
    }

    private static func decodeBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    /// Persisted keys require migration when renamed.
    public enum Keys {
        public static let themeId = "theme.id"
        public static let typographyID = "typography.id"
        public static let userPersonalization = "userPersonalization"
        /// Read only for migration; do not write new values under this key.
        public static let legacySystemPrompt = "systemPrompt"
        public static let defaultVerbosity = "defaultVerbosity"
        public static let fontScale = "appearance.fontScale"
        public static let autoCompactEnabled = "compaction.autoEnabled"
        public static let autoCompactThreshold = "compaction.threshold"
        public static let lastSelectedModelId = "lastSelectedModel.id"
        public static let webSearchAskBeforeSearching = "webSearch.askBeforeSearching"
        public static let summarizeTitles = "titles.summarizeEnabled"
        public static let titleModelId = "titles.modelId"
        public static let hapticsEnabled = "haptics.enabled"
        public static func modelEnabled(id: String) -> String {
            "models.enabled.\(id)"
        }
    }
}
