import Foundation

/// User-tunable Chat preferences resolved into a single typed value.
///
/// The Chat applet persists each field individually through
/// `SettingRepository` (one row per key, opaque string values). This struct
/// is the in-memory projection — `ChatSettingsStore` is the bridge.
public struct ChatSettings: Sendable, Equatable {
    /// Visual theme. Drives `SuperTheme.make(_:)` selection.
    /// Wired live: `ChatHostView` rebuilds its theme on change.
    public var themeId: ThemeID
    /// Active typography identity. Drives `SuperTypography.make(_:)`
    /// selection — the brand serif face set vs. the system fallback.
    /// Wired live: `AppShell` rebuilds typography on change. No
    /// user-facing picker yet; the key exists so swapping the brand
    /// face app-wide is a one-value change.
    public var typographyID: TypographyID
    /// Free-form user "about me" text — preferences, name, tone notes
    /// the assistant should keep in mind. Injected as the
    /// `## User personalization` section at the *end* of the leading
    /// `.system` block by `ContextAssembler` so it follows, never
    /// overrides, the authoritative chat and applet sections. Edits via
    /// Settings → Personalization are pushed to active `ChatSession`s
    /// through `ChatSessionStore.setUserPersonalization` so long-running
    /// conversations pick up the new value on the next turn.
    /// Empty / whitespace-only values skip injection. Replaces the
    /// previous `systemPrompt` field (which exposed the assistant's
    /// orchestration text to the user — see the migration in
    /// `ChatSettingsStore.load()`).
    public var userPersonalization: String
    /// Default verbosity for new chats. Existing chats keep their own.
    /// Wired live: `ChatHostView.startNewChat` reads it.
    public var defaultVerbosity: ChatVerbosity
    /// Body-font scale multiplier. Clamped to `[0.80, 1.20]`. Applied
    /// to message rendering via the `\.chatAppearance` environment value
    /// injected by `ChatHostView` — see `ChatAppearance`. This is the
    /// sole appearance knob: spacing (line-spacing, paragraph margin,
    /// bubble paddings) is derived from `fontScale` inside
    /// `ChatAppearance` so larger text always gets more breathing room.
    public var fontScale: Double
    /// Whether the compactor automatically runs when context fills up.
    /// Persistence wired in M9; the `ChatSession` toggle hookup is M10
    /// alongside the in-chat manual-compact affordance.
    public var autoCompactEnabled: Bool
    /// Fraction of `maxContextTokens` (0.0–1.0) at which auto-compaction
    /// fires. Persisted now; consumed alongside `autoCompactEnabled` in M10.
    public var autoCompactThreshold: Double
    /// **Record id** (`ModelConfigurationRecord.id`) of the model the user most
    /// recently activated in the composer pill — the unique per-model identity,
    /// not the shared `modelId`. Used as the initial selection for every new
    /// chat so the picker survives relaunch. `nil` until the first chat has been
    /// opened and the initial pick has been persisted; subsequent launches
    /// always read a populated value. (Legacy values stored as an `LLMModel.id`
    /// before the record-id convergence still resolve via the back-compat
    /// branch in `ChatScreenViewModel.resolveInitialModelId`, then re-persist as
    /// a record id on the next pick.)
    public var lastSelectedModelId: String?
    /// Native web-search cost gate. When `true` (the default), a model's
    /// web-search request is surfaced as an inline confirm prompt
    /// ("Search the web?") before any search runs — searches cost money,
    /// so the user approves each one. When `false`, searches run without
    /// prompting. Wired live: edits in Settings → Search are pushed to
    /// active `ChatSession`s via the `WebSearchPolicyReceiver` seam so a
    /// long-running conversation picks up the new value on its next turn.
    public var askBeforeSearching: Bool
    /// Whether chat titles are auto-summarized by a headless LLM call after
    /// the first exchange. When `false`, the title stays the truncated first
    /// user message (see `ChatScreenViewModel.truncatedFallback`). Default
    /// `true`. The *which model* knob is `titleModelId`; this is the master
    /// on/off so the user can avoid the round-trip (and its cost) entirely.
    public var summarizeTitlesEnabled: Bool
    /// **Record id** (`ModelConfigurationRecord.id`) of the model used to
    /// summarize chat titles — the unique per-model identity, not the shared
    /// `modelId` — or `nil` for "automatic" (which resolves to the Apple
    /// Foundation Model when available, else no titling). A stored id that no
    /// longer maps to an available model (the model was deleted) also resolves
    /// to none rather than reverting to AFM. Resolution (incl. the legacy
    /// `LLMModel.id` back-compat branch) lives in
    /// `TitleGenerator.resolveTitleModel`. Independent of the chat's active
    /// model — titling can use a different model than the conversation.
    public var titleModelId: String?

    /// Factory default for `autoCompactThreshold` — the fraction of
    /// `model.maxContextTokens` at which background auto-compaction fires.
    /// Single source of truth: `ChatSession.init`, `ChatSessionStore.init`,
    /// and `ChatSettings.default` all reference this constant so the
    /// defaults can't drift apart.
    public static let defaultAutoCompactThreshold: Double = 0.85

    /// Minimum context-usage ratio below which manual `/compact` refuses
    /// to run and surfaces a user-facing error instead. Below this, the
    /// summary would be too short to be worth the round-trip and the
    /// resulting checkpoint would represent almost the whole conversation.
    /// Not user-tunable today; lives as a named constant so the value
    /// has one home.
    public static let defaultManualCompactMinThreshold: Double = 0.30

    /// Factory defaults. `userPersonalization` defaults to the empty
    /// string — the leading `.system` block omits the
    /// `## User personalization` section entirely when the field is
    /// empty.
    public static let `default` = ChatSettings(
        themeId: .vellumLight,
        typographyID: .serif,
        userPersonalization: "",
        defaultVerbosity: .simple,
        fontScale: 1.0,
        autoCompactEnabled: true,
        autoCompactThreshold: defaultAutoCompactThreshold,
        lastSelectedModelId: nil,
        askBeforeSearching: true,
        summarizeTitlesEnabled: true,
        titleModelId: nil
    )

    public init(
        themeId: ThemeID,
        typographyID: TypographyID,
        userPersonalization: String,
        defaultVerbosity: ChatVerbosity,
        fontScale: Double,
        autoCompactEnabled: Bool,
        autoCompactThreshold: Double,
        lastSelectedModelId: String? = nil,
        askBeforeSearching: Bool = true,
        summarizeTitlesEnabled: Bool = true,
        titleModelId: String? = nil
    ) {
        self.themeId = themeId
        self.typographyID = typographyID
        self.userPersonalization = userPersonalization
        self.defaultVerbosity = defaultVerbosity
        self.fontScale = ChatSettings.clampFontScale(fontScale)
        self.autoCompactEnabled = autoCompactEnabled
        self.autoCompactThreshold = ChatSettings.clampThreshold(autoCompactThreshold)
        self.lastSelectedModelId = lastSelectedModelId
        self.askBeforeSearching = askBeforeSearching
        self.summarizeTitlesEnabled = summarizeTitlesEnabled
        self.titleModelId = titleModelId
    }

    /// Mirror of `SuperTheme.Identifier` (8 variants: four families ×
    /// light/dark). Re-declared (rather than typealiased) so persistence
    /// string values stay stable even if the SuperTheme enum gains a case the
    /// store doesn't recognize yet. Legacy persisted strings (`light`/`dark`/
    /// `sepia`, and the retired `sepiaLight`/`sepiaDark`) are migrated to these
    /// in `ChatSettingsStore.migrateThemeID`.
    public enum ThemeID: String, Sendable, Equatable, CaseIterable, Codable {
        case vellumLight
        case vellumDark
        case lapisLight
        case lapisDark
        case scriptoriumLight
        case scriptoriumDark
        case slateLight
        case slateDark
    }

    /// Mirror of `SuperTypography.Identifier`. Re-declared (rather than
    /// typealiased) for the same reason as `ThemeID`: persistence string
    /// values stay stable even if the Core enum gains a case the store
    /// doesn't recognize yet. Bridged to `SuperTypography` via
    /// `SuperTypography.make(_:fontScale:)` in `SettingsSheet`.
    public enum TypographyID: String, Sendable, Equatable, CaseIterable, Codable {
        case serif
        case system
    }

    static func clampFontScale(_ value: Double) -> Double {
        min(max(value, 0.80), 1.20)
    }

    static func clampThreshold(_ value: Double) -> Double {
        min(max(value, 0.5), 0.95)
    }
}
