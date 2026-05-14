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
    /// System prompt injected as the leading `.system` LLMMessage on every
    /// turn by `ContextAssembler`. Edits via Settings → Prompt are pushed
    /// to active `ChatSession`s through `ChatSessionStore.setSystemPrompt`
    /// so long-running conversations pick up the new value on the next
    /// turn. Empty / whitespace-only values skip injection.
    public var systemPrompt: String
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

    /// Factory defaults. `systemPrompt` is loaded once from
    /// `Resources/DefaultSystemPrompt.md` shipped in `Bundle.module`; all
    /// other fields are inline literals. A user who has edited
    /// Settings → Prompt keeps their value — `ChatSettingsStore.load()`
    /// only falls back to this default when no row exists for the key.
    public static let `default` = ChatSettings(
        themeId: .light,
        systemPrompt: bundledDefaultSystemPrompt,
        defaultVerbosity: .simple,
        fontScale: 1.0,
        autoCompactEnabled: true,
        autoCompactThreshold: defaultAutoCompactThreshold,
        lastSelectedModelId: nil
    )

    /// Contents of the bundled `DefaultSystemPrompt.md`, trimmed of
    /// surrounding whitespace. Loaded once at type init; a missing
    /// resource is a packaging bug, not a runtime condition — fail loud.
    private static let bundledDefaultSystemPrompt: String = _loadBundledDefaultSystemPrompt()

    /// Reads `Resources/DefaultSystemPrompt.md` from `Bundle.module`
    /// fresh on every call. Underscore-prefixed because the only legitimate
    /// caller outside the static-let cache is `ChatSettingsTests`, which
    /// uses it to verify `default.systemPrompt` matches an independent
    /// read of the on-disk file (catches a silent revert to a hardcoded
    /// literal). Production reads should go through
    /// `ChatSettings.default.systemPrompt`, which caches the result.
    static func _loadBundledDefaultSystemPrompt() -> String {
        // `.process("Resources")` in `Package.swift` flattens the directory
        // into the bundle root, so the file is looked up without a
        // `subdirectory:` argument. Changing the Package.swift directive
        // back to `.copy` without restoring `subdirectory: "Resources"`
        // here would silently return nil → fatalError.
        guard let url = Bundle.module.url(
            forResource: "DefaultSystemPrompt",
            withExtension: "md"
        ) else {
            fatalError("DefaultSystemPrompt.md missing from Chat bundle resources")
        }
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            fatalError("DefaultSystemPrompt.md present but unreadable as UTF-8: \(error)")
        }
    }

    public init(
        themeId: ThemeID,
        systemPrompt: String,
        defaultVerbosity: ChatVerbosity,
        fontScale: Double,
        autoCompactEnabled: Bool,
        autoCompactThreshold: Double,
        lastSelectedModelId: String? = nil
    ) {
        self.themeId = themeId
        self.systemPrompt = systemPrompt
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
