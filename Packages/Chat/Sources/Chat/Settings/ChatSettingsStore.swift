import Foundation

/// Reads and writes `ChatSettings` against a `SettingRepository`. Each field
/// lives under its own `SettingRecord.key` (one row per setting) so we can
/// add a new setting without a schema migration.
///
/// The store is a tiny stateless wrapper: it does not cache. Callers that
/// want a single resolved value should call `load()` once and hold the
/// result themselves (e.g. `SettingsViewModel`).
public struct ChatSettingsStore: Sendable {
    private let repository: any SettingRepository

    public init(repository: any SettingRepository) {
        self.repository = repository
    }

    /// Read every persisted key, falling back to `ChatSettings.default` for
    /// missing or unrecognized values. Never throws — a corrupted row reads
    /// as the default.
    public func load() async -> ChatSettings {
        let raw = (try? await repository.all()) ?? [:]
        return ChatSettings(
            themeId: raw[Keys.themeId].flatMap(ChatSettings.ThemeID.init(rawValue:))
                ?? ChatSettings.default.themeId,
            systemPrompt: raw[Keys.systemPrompt] ?? ChatSettings.default.systemPrompt,
            defaultVerbosity: raw[Keys.defaultVerbosity].flatMap(ChatVerbosity.init(rawValue:))
                ?? ChatSettings.default.defaultVerbosity,
            fontScale: raw[Keys.fontScale].flatMap(Double.init)
                ?? ChatSettings.default.fontScale,
            autoCompactEnabled: raw[Keys.autoCompactEnabled].flatMap(Self.decodeBool)
                ?? ChatSettings.default.autoCompactEnabled,
            autoCompactThreshold: raw[Keys.autoCompactThreshold].flatMap(Double.init)
                ?? ChatSettings.default.autoCompactThreshold,
            lastSelectedModelId: raw[Keys.lastSelectedModelId]
        )
    }

    public func setTheme(_ themeId: ChatSettings.ThemeID) async throws {
        try await repository.set(Keys.themeId, value: themeId.rawValue)
    }

    public func setSystemPrompt(_ value: String) async throws {
        try await repository.set(Keys.systemPrompt, value: value)
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

    /// Persists the upstream `LLMModel.id` the user just activated so the
    /// next new chat opens on the same model. Stale ids (the model has
    /// since been deleted) are tolerated at read time — `ContentView`
    /// falls back to the first available model when the persisted id is
    /// no longer registered.
    public func setLastSelectedModelId(_ id: String) async throws {
        try await repository.set(Keys.lastSelectedModelId, value: id)
    }

    /// Whether the user has flipped this model on in Settings. nil ⇒ no
    /// row, treat as the registration default ("on" today).
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

    /// Stable string keys used inside the `setting` table. Centralized
    /// here so the view model never embeds a literal — and so renaming a
    /// field (e.g. dropping the `appearance.` prefix later) requires
    /// editing exactly one place plus a migration.
    public enum Keys {
        /// `ChatSettings.ThemeID` rawValue. Active theme.
        public static let themeId = "theme.id"
        /// Plain-text system prompt prepended to new chats.
        public static let systemPrompt = "systemPrompt"
        /// `ChatVerbosity` rawValue used when creating a fresh chat.
        public static let defaultVerbosity = "defaultVerbosity"
        /// String-encoded Double in `[0.80, 1.20]`.
        public static let fontScale = "appearance.fontScale"
        /// `"true"` / `"false"`. Whether auto-compaction is on.
        public static let autoCompactEnabled = "compaction.autoEnabled"
        /// String-encoded Double in `[0.5, 0.95]`. Fraction of context
        /// at which auto-compaction fires.
        public static let autoCompactThreshold = "compaction.threshold"
        /// `LLMModel.id` of the model most recently activated in the
        /// composer pill. Bootstraps the initial pick of every new chat.
        public static let lastSelectedModelId = "lastSelectedModel.id"
        /// Per-model enabled flag. Keyed by `id` so each row stays
        /// independent of the others.
        public static func modelEnabled(id: String) -> String {
            "models.enabled.\(id)"
        }
    }
}
