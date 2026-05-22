import Core
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
    ///
    /// Runs the one-shot legacy-`systemPrompt` migration when needed: if
    /// the new `userPersonalization` key is absent but the old
    /// `systemPrompt` key exists, compare the stored value against the
    /// `LegacyDefaultSystemPromptV1.md` snapshot — when they match (the
    /// common case, user never edited the default) the legacy row is
    /// deleted silently; otherwise the user's custom text carries forward
    /// as their personalization and the legacy row is cleared. The
    /// migration only fires once per device because subsequent loads see
    /// the new key populated (or explicitly empty after a clean migrate).
    public func load() async -> ChatSettings {
        let raw = (try? await repository.all()) ?? [:]
        let personalization = await resolveUserPersonalization(raw: raw)
        return ChatSettings(
            themeId: raw[Keys.themeId].flatMap(ChatSettings.ThemeID.init(rawValue:))
                ?? ChatSettings.default.themeId,
            userPersonalization: personalization,
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

    /// Pick the right `userPersonalization` value out of a row dictionary,
    /// running the legacy migration when the new key is absent. Side-effects
    /// (deleting the legacy row, writing the new key) are best-effort — a
    /// transient repository failure leaves the legacy row in place and the
    /// migration will retry on the next load.
    private func resolveUserPersonalization(raw: [String: String]) async -> String {
        if let value = raw[Keys.userPersonalization] {
            // Best-effort cleanup of the legacy key now that the new
            // key has been written — covers the rare race where both
            // were stored simultaneously. Without this the orphan row
            // would live indefinitely; deleting it here makes the
            // migration fully idempotent.
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
            // The stored value is the previous bundled default (or empty)
            // — the user never customized. Clear the legacy row and
            // surface the empty personalization.
            try? await repository.delete(Keys.legacySystemPrompt)
            return ChatSettings.default.userPersonalization
        }
        // User edited the previous system prompt. Carry the custom text
        // forward as their personalization — they can clear or edit it
        // from the new Personalization pane.
        try? await repository.set(Keys.userPersonalization, value: legacy)
        try? await repository.delete(Keys.legacySystemPrompt)
        return legacy
    }

    /// Snapshot of the previous build's `DefaultSystemPrompt.md`. Used by
    /// the migration to detect users who never edited it. Loaded once at
    /// type init; a missing snapshot resolves to empty (which then makes
    /// the migration carry every legacy value forward — safe-but-noisy
    /// fallback that lets the user prune unwanted text rather than
    /// silently losing customizations).
    ///
    /// Package-internal (rather than `private`) so the migration tests
    /// can read the same source-of-truth the production code reads —
    /// the test target's `Bundle.module` is a different bundle from the
    /// Chat target's, so a test must reach in through this seam to get
    /// the bundled-into-Chat snapshot.
    static let legacyDefaultSystemPrompt: String = AppletSystemPrompt.load(
        from: .module,
        resource: "LegacyDefaultSystemPromptV1"
    )

    public func setTheme(_ themeId: ChatSettings.ThemeID) async throws {
        try await repository.set(Keys.themeId, value: themeId.rawValue)
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
        /// User-authored personalization / "about me" text (was
        /// `systemPrompt` in the previous release; see
        /// `legacySystemPrompt` for the migration path).
        public static let userPersonalization = "userPersonalization"
        /// Legacy key from before the personalization reframe. Kept here
        /// so `load()` can run the one-shot migration; never written by
        /// production code after the reframe shipped.
        public static let legacySystemPrompt = "systemPrompt"
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
