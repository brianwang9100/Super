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
    /// `LLMModel.id` (e.g. `"claude-opus-4-7"`) of the model the user most
    /// recently activated in the composer pill. Used as the initial
    /// selection for every new chat so the picker survives relaunch.
    /// `nil` until the first chat has been opened and the initial pick
    /// has been persisted; subsequent launches always read a populated value.
    public var lastSelectedModelId: String?

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
        themeId: .light,
        userPersonalization: "",
        defaultVerbosity: .simple,
        fontScale: 1.0,
        autoCompactEnabled: true,
        autoCompactThreshold: defaultAutoCompactThreshold,
        lastSelectedModelId: nil
    )

    public init(
        themeId: ThemeID,
        userPersonalization: String,
        defaultVerbosity: ChatVerbosity,
        fontScale: Double,
        autoCompactEnabled: Bool,
        autoCompactThreshold: Double,
        lastSelectedModelId: String? = nil
    ) {
        self.themeId = themeId
        self.userPersonalization = userPersonalization
        self.defaultVerbosity = defaultVerbosity
        self.fontScale = ChatSettings.clampFontScale(fontScale)
        self.autoCompactEnabled = autoCompactEnabled
        self.autoCompactThreshold = ChatSettings.clampThreshold(autoCompactThreshold)
        self.lastSelectedModelId = lastSelectedModelId
    }

    /// Mirror of `SuperTheme.Identifier`. Re-declared (rather than typealiased)
    /// so persistence string values stay stable even if the SuperTheme enum
    /// gains a fourth case the store doesn't recognize yet.
    public enum ThemeID: String, Sendable, Equatable, CaseIterable, Codable {
        case light
        case dark
        case sepia
    }

    static func clampFontScale(_ value: Double) -> Double {
        min(max(value, 0.80), 1.20)
    }

    static func clampThreshold(_ value: Double) -> Double {
        min(max(value, 0.5), 0.95)
    }
}
