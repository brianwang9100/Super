import SwiftUI

/// User-tunable chat-reading appearance: font scale (0.85×–1.15×) and
/// vertical density preset. Persisted in `ChatSettings` and projected
/// onto the SwiftUI environment so the message renderer, user bubble,
/// streaming tail, and assistant message row all repaint when either
/// knob changes. Mirrors the `\.superTheme` injection pattern in
/// ``SuperTheme``.
///
/// The `default` value matches today's hardcoded sizing (15pt body,
/// `.em(0.18)` paragraph line-spacing, 4pt outer / 10pt inner bubble
/// padding) so views that don't yet read the environment behave
/// exactly as they did before this type existed.
public struct ChatAppearance: Sendable, Equatable {
    public let fontScale: Double
    public let density: ChatSettings.Density

    public init(fontScale: Double, density: ChatSettings.Density) {
        self.fontScale = fontScale
        self.density = density
    }

    public static let `default` = ChatAppearance(fontScale: 1.0, density: .comfortable)

    /// Absolute body font size in points. Headings and inline code that
    /// use `.em(...)` scale automatically because MarkdownUI resolves
    /// em values against this base. Not Dynamic-Type responsive — that's
    /// a property of MarkdownUI's `FontSize(...)`, which doesn't read
    /// SwiftUI's environment. Plain `Text` views that want Dynamic Type
    /// on top of `fontScale` should declare a local `@ScaledMetric`
    /// (see ``UserBubble`` for the pattern).
    public var bodyFontSize: CGFloat { 15 * fontScale }

    /// SwiftUI `Font` matching `bodyFontSize`. Convenience for views that
    /// explicitly want a fixed (non-Dynamic-Type) body font scaled only
    /// by `fontScale`. For Dynamic-Type-responsive scaling on top of
    /// `fontScale`, use a local `@ScaledMetric` instead.
    public var bodyFont: Font { .system(size: bodyFontSize) }

    /// Paragraph line-spacing as an em multiplier passed to MarkdownUI's
    /// `relativeLineSpacing`. Resolves against `bodyFontSize`, so a
    /// spacious + small-scale combination still reads tighter than a
    /// spacious + large-scale combination.
    public var paragraphLineSpacingEm: CGFloat {
        switch density {
        case .compact: return 0.10
        case .comfortable: return 0.18
        case .spacious: return 0.28
        }
    }

    /// Vertical padding inside the user-bubble shape (between the bubble
    /// fill and the text). Scales with density.
    public var bubbleInnerVerticalPadding: CGFloat {
        switch density {
        case .compact: return 6
        case .comfortable: return 10
        case .spacious: return 14
        }
    }

    /// Vertical padding around the user-bubble row in the message list.
    /// Combined with ``assistantRowVerticalPadding`` on the neighboring
    /// row, this drives the air between adjacent message rows — the
    /// asymmetry (user 2/4/8 vs assistant 1/2/4) is intentional because
    /// the markdown body inside assistant rows already contributes
    /// `markdownMargin` between blocks.
    public var bubbleRowVerticalPadding: CGFloat {
        switch density {
        case .compact: return 2
        case .comfortable: return 4
        case .spacious: return 8
        }
    }

    /// Vertical padding around assistant-side rows (`AssistantMessage`,
    /// `StreamingTail`). Half the user-bubble row padding because the
    /// markdown body inside the row already contributes its own
    /// `markdownMargin` between blocks; doubling up here would compound.
    public var assistantRowVerticalPadding: CGFloat {
        switch density {
        case .compact: return 1
        case .comfortable: return 2
        case .spacious: return 4
        }
    }
}

public struct ChatAppearanceKey: EnvironmentKey {
    public static let defaultValue: ChatAppearance = .default
}

public extension EnvironmentValues {
    var chatAppearance: ChatAppearance {
        get { self[ChatAppearanceKey.self] }
        set { self[ChatAppearanceKey.self] = newValue }
    }
}

public extension View {
    /// Inject a `ChatAppearance` into the SwiftUI environment for this
    /// subtree. Pair with `.superTheme(_:)` at the same composition
    /// boundary so theme and appearance refresh together.
    func chatAppearance(_ appearance: ChatAppearance) -> some View {
        environment(\.chatAppearance, appearance)
    }
}
