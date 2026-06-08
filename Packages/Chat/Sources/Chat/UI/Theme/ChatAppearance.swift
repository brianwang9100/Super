import Core
import SwiftUI

/// User-tunable chat-reading appearance, controlled by a single
/// `fontScale` knob (0.80×–1.20×). Persisted in `ChatSettings` and
/// projected onto the SwiftUI environment so the message renderer,
/// user bubble, streaming tail, and assistant message row all repaint
/// when it changes. Mirrors the `\.superTheme` injection pattern in
/// ``SuperTheme``.
///
/// Spacing (intra-paragraph line spacing, inter-paragraph margin,
/// bubble paddings) is derived from `fontScale` via piecewise-linear
/// interpolation between three anchors:
/// - `0.80×` → compact spacing
/// - `1.00×` → comfortable spacing (the `default`, tuned to match
///   Claude's iOS chat reading feel)
/// - `1.20×` → spacious spacing
///
/// Collapsing density into the font slider keeps the appearance pane
/// to one knob and guarantees that larger text always gets more
/// breathing room.
public struct ChatAppearance: Sendable, Equatable {
    public let fontScale: Double

    /// Defensive clamp at the boundary: `ChatSettings.clampFontScale`
    /// already pins the persisted value to `[0.80, 1.20]`, but a future
    /// caller (test, migration, debug seam) could construct a
    /// `ChatAppearance` directly and bypass that. Re-clamping here keeps
    /// the doc-comment contract honest even on the direct path.
    public init(fontScale: Double) {
        self.fontScale = min(max(fontScale, 0.80), 1.20)
    }

    public static let `default` = ChatAppearance(fontScale: 1.0)

    /// Absolute body font size in points. Headings and inline code that
    /// use `.em(...)` scale automatically because MarkdownUI resolves
    /// em values against this base. Not Dynamic-Type responsive — that's
    /// a property of MarkdownUI's `FontSize(...)`, which doesn't read
    /// SwiftUI's environment. Plain `Text` views that want Dynamic Type
    /// on top of `fontScale` should declare a local `@ScaledMetric`
    /// (see ``UserBubble`` for the pattern).
    public var bodyFontSize: CGFloat { SuperTypography.readingBodySize * fontScale }

    /// Paragraph line-spacing as an em multiplier passed to MarkdownUI's
    /// `relativeLineSpacing`. A constant `SuperTypography.readingLeadingEm`
    /// (≈0.235 em) shared with the Bible reader so both EB Garamond reading
    /// surfaces have identical line rhythm. Resolves against `bodyFontSize`,
    /// so the gap still grows in absolute points as the slider enlarges the
    /// body — but the *ratio* stays fixed rather than loosening with the slider.
    public var paragraphLineSpacingEm: CGFloat {
        SuperTypography.readingLeadingEm
    }

    /// Intra-paragraph line spacing as *points* — ``paragraphLineSpacingEm``
    /// resolved against ``bodyFontSize`` — for APIs that take an absolute
    /// `CGFloat` rather than an em. Used for the gap *between* list items
    /// (`markdownMargin(top:)` is point-valued, not em), so a bulleted or
    /// numbered list's item-to-item spacing reads with the same rhythm as the
    /// wrapped lines inside an item instead of bunching at a fixed 2pt. It
    /// closely tracks — but isn't bit-identical to — the gap
    /// `relativeLineSpacing(.em:)` actually paints, which MarkdownUI rounds
    /// internally (≈`round(em · round(bodyFontSize))`); the sub-point
    /// difference is below visual threshold.
    public var paragraphLineSpacingPoints: CGFloat {
        paragraphLineSpacingEm * bodyFontSize
    }

    /// Vertical margin below each markdown paragraph, in points. Drives
    /// the *gap between paragraphs* (distinct from intra-paragraph line
    /// spacing, which `paragraphLineSpacingEm` controls). A constant `16/17`
    /// em (≈0.94) of ``bodyFontSize`` — like the leading, the *ratio* is fixed
    /// and only the body it multiplies grows with the slider, so the gap holds
    /// at ≈0.76 of a line at every slider position instead of swelling toward a
    /// full empty line at the top end. Resolves to ≈14.3 / 17.9 / 21.5pt at the
    /// 0.8× / 1.0× / 1.2× slider over the 19pt body. Reads as a comfortable
    /// three-quarter-line gap, matching the rhythm of Claude's iOS chat.
    public var paragraphSpacing: CGFloat {
        (16.0 / 17.0) * bodyFontSize
    }

    /// Vertical padding inside the user-bubble shape (between the bubble
    /// fill and the text). Grows with the font slider.
    public var bubbleInnerVerticalPadding: CGFloat {
        interpolate(low: 6, mid: 10, high: 14)
    }

    /// Vertical padding around the user-bubble row in the message list.
    /// Combined with ``assistantRowVerticalPadding`` on the neighboring
    /// row, this drives the air between adjacent message rows — the
    /// asymmetry (user 2/4/8 vs assistant 1/2/4 at the anchors) is
    /// intentional because the markdown body inside assistant rows
    /// already contributes `markdownMargin` between blocks.
    public var bubbleRowVerticalPadding: CGFloat {
        interpolate(low: 2, mid: 4, high: 8)
    }

    /// Vertical padding around assistant-side rows (`AssistantMessage`,
    /// `StreamingTail`). Half the user-bubble row padding because the
    /// markdown body inside the row already contributes its own
    /// `markdownMargin` between blocks; doubling up here would compound.
    public var assistantRowVerticalPadding: CGFloat {
        interpolate(low: 1, mid: 2, high: 4)
    }

    /// Piecewise-linear interpolation between the three font-scale
    /// anchors. `low` is the value at `fontScale == 0.80`, `mid` at
    /// `1.00`, and `high` at `1.20`. The init clamps `fontScale` into
    /// `[0.80, 1.20]`, so the interpolation parameter is always in
    /// `[0, 1]` on either segment. The mid anchor is special-cased so
    /// the documented 1.0× anchor returns `mid` exactly (`(1.0 - 0.8)
    /// / 0.2` is one ULP off true `1.0` in IEEE-754 binary, which
    /// would otherwise yield `mid ± ε`).
    private func interpolate(low: CGFloat, mid: CGFloat, high: CGFloat) -> CGFloat {
        let scale = CGFloat(fontScale)
        if scale == 1.0 { return mid }
        if scale < 1.0 {
            let t = (scale - 0.80) / 0.20
            return low + (mid - low) * t
        } else {
            let t = (scale - 1.00) / 0.20
            return mid + (high - mid) * t
        }
    }
}

/// SwiftUI environment plumbing — only the `\.chatAppearance` accessor
/// and `View.chatAppearance(_:)` modifier are part of the public surface.
/// The key itself stays internal so it isn't re-exported as API surface.
struct ChatAppearanceKey: EnvironmentKey {
    static let defaultValue: ChatAppearance = .default
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
