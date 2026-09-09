import Foundation

public struct ChatSettings: Sendable, Equatable {
    public var themeId: ThemeID
    public var typographyID: TypographyID
    /// Appended after authoritative system instructions; blank text is omitted.
    /// Changes reach active sessions on their next turn.
    public var userPersonalization: String
    /// Applies to new chats; existing chats retain their own verbosity.
    public var defaultVerbosity: ChatVerbosity
    /// App font-scale multiplier, clamped to [0.80, 1.20].
    public var fontScale: Double
    public var autoCompactEnabled: Bool
    /// Fraction of maxContextTokens at which automatic compaction starts.
    public var autoCompactThreshold: Double
    /// ModelConfigurationRecord.id, not the shared upstream modelId.
    /// Legacy LLMModel IDs resolve through ChatScreenViewModel.resolveInitialModelId.
    public var lastSelectedModelId: String?
    public var askBeforeSearching: Bool
    public var summarizeTitlesEnabled: Bool
    /// ModelConfigurationRecord.id; nil selects AFM when available.
    /// A stale explicit selection disables titling instead of falling back to AFM.
    public var titleModelId: String?
    public var hapticsEnabled: Bool

    public static let defaultAutoCompactThreshold: Double = 0.85

    /// Small-window token estimates undercount provider overhead; compact earlier
    /// to leave room for the summary request.
    public static let compactTierAutoCompactThreshold: Double = 0.6

    /// Below this usage, a summary costs a round trip without meaningfully reducing context.
    public static let defaultManualCompactMinThreshold: Double = 0.30

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
        titleModelId: nil,
        hapticsEnabled: true
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
        titleModelId: String? = nil,
        hapticsEnabled: Bool = true
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
        self.hapticsEnabled = hapticsEnabled
    }

    /// Separate from SuperTheme.Identifier to keep persistence independent of Core enum changes.
    /// ChatSettingsStore migrates retired theme values.
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

    /// Separate from the Core enum to stabilize persisted values, as with ThemeID.
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
