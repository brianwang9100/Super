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
    /// System prompt prepended to new conversations.
    /// Persistence wired in M9; consumption by `SystemPromptBuilder` is
    /// the M10 task documented in `IMPLEMENTATION_STATUS.md`.
    public var systemPrompt: String
    /// Default verbosity for new chats. Existing chats keep their own.
    /// Wired live: `ChatHostView.startNewChat` reads it.
    public var defaultVerbosity: ChatVerbosity
    /// Body-font scale multiplier. Clamped to `[0.85, 1.15]`. Applied
    /// to message rendering via the `\.chatAppearance` environment value
    /// injected by `ChatHostView` — see `ChatAppearance`.
    public var fontScale: Double
    /// Vertical density preset. Drives paragraph line-spacing inside
    /// markdown and per-row vertical padding on user/assistant message
    /// rows via the `\.chatAppearance` environment value — see
    /// `ChatAppearance`. Composer and sidebar chrome stay fixed-size.
    public var density: Density
    /// Whether the compactor automatically runs when context fills up.
    /// Persistence wired in M9; the `ChatSession` toggle hookup is M10
    /// alongside the in-chat manual-compact affordance.
    public var autoCompactEnabled: Bool
    /// Fraction of `maxContextTokens` (0.0–1.0) at which auto-compaction
    /// fires. Persisted now; consumed alongside `autoCompactEnabled` in M10.
    public var autoCompactThreshold: Double

    public static let `default` = ChatSettings(
        themeId: .light,
        systemPrompt: "You are Super, a thoughtful personal assistant. Answer directly and well.",
        defaultVerbosity: .simple,
        fontScale: 1.0,
        density: .comfortable,
        autoCompactEnabled: true,
        autoCompactThreshold: 0.85
    )

    public init(
        themeId: ThemeID,
        systemPrompt: String,
        defaultVerbosity: ChatVerbosity,
        fontScale: Double,
        density: Density,
        autoCompactEnabled: Bool,
        autoCompactThreshold: Double
    ) {
        self.themeId = themeId
        self.systemPrompt = systemPrompt
        self.defaultVerbosity = defaultVerbosity
        self.fontScale = ChatSettings.clampFontScale(fontScale)
        self.density = density
        self.autoCompactEnabled = autoCompactEnabled
        self.autoCompactThreshold = ChatSettings.clampThreshold(autoCompactThreshold)
    }

    /// Mirror of `SuperTheme.Identifier`. Re-declared (rather than typealiased)
    /// so persistence string values stay stable even if the SuperTheme enum
    /// gains a fourth case the store doesn't recognize yet.
    public enum ThemeID: String, Sendable, Equatable, CaseIterable, Codable {
        case light
        case dark
        case sepia
    }

    /// Three discrete vertical-spacing presets consumed by the
    /// `\.chatAppearance` environment value — see `ChatAppearance` for
    /// the resolved per-row paddings and paragraph line-spacing values.
    public enum Density: String, Sendable, Equatable, CaseIterable, Codable {
        case compact
        case comfortable
        case spacious

        /// Title-cased label for the Appearance pane row.
        public var displayName: String {
            switch self {
            case .compact: return "Compact"
            case .comfortable: return "Comfortable"
            case .spacious: return "Spacious"
            }
        }
    }

    static func clampFontScale(_ value: Double) -> Double {
        min(max(value, 0.85), 1.15)
    }

    static func clampThreshold(_ value: Double) -> Double {
        min(max(value, 0.5), 0.95)
    }
}
