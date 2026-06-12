import SwiftUI

/// Body-size and paragraph-rhythm inputs for the shared markdown
/// renderer (``MarkdownText``), decoupled from any one applet's
/// appearance model.
///
/// Everything derives from a single `fontScale` knob against the brand
/// reading body (`SuperTypography.readingBodySize`): the leading and
/// paragraph-gap ratios are constants, so a host that scales the body —
/// like Chat's font-scale slider — projects its scale here and the
/// spacing follows at the same fixed ratios. Hosts that don't inject
/// anything render at the environment default (1.0×), which matches
/// Chat at the slider's center.
public struct MarkdownBodyMetrics: Sendable, Equatable {
    /// Multiplier over the 19pt reading body, expected in `[0.80, 1.20]`
    /// (the host clamps; this struct doesn't re-clamp so the derived
    /// values stay an exact projection of the host's knob).
    public let fontScale: CGFloat

    public init(fontScale: CGFloat) {
        self.fontScale = fontScale
    }

    /// The unscaled reading body shared with the Bible reader and Chat
    /// at the slider's 1.0× center.
    public static let `default` = MarkdownBodyMetrics(fontScale: 1.0)

    /// Absolute body font size in points. Headings and inline code in
    /// the markdown theme use `.em(...)` and scale automatically against
    /// this base. Not Dynamic-Type responsive — MarkdownUI's
    /// `FontSize(...)` doesn't read SwiftUI's environment.
    public var bodyFontSize: CGFloat { SuperTypography.readingBodySize * fontScale }

    /// Intra-paragraph line spacing as an em multiplier for MarkdownUI's
    /// `relativeLineSpacing`. The constant `SuperTypography.readingLeadingEm`
    /// (≈0.235 em) shared with the Bible reader, so every EB Garamond
    /// reading surface has identical line rhythm regardless of body size.
    public var paragraphLineSpacingEm: CGFloat {
        SuperTypography.readingLeadingEm
    }

    /// ``paragraphLineSpacingEm`` resolved against ``bodyFontSize`` for
    /// point-valued APIs (`markdownMargin(top:)` between list items).
    public var paragraphLineSpacingPoints: CGFloat {
        paragraphLineSpacingEm * bodyFontSize
    }

    /// Vertical margin below each markdown paragraph, in points. A
    /// constant `16/17` em (≈0.94) of ``bodyFontSize`` — a comfortable
    /// three-quarter-line gap whose *ratio* holds at every body size.
    public var paragraphSpacing: CGFloat {
        (16.0 / 17.0) * bodyFontSize
    }
}

/// SwiftUI environment plumbing — only the `\.markdownBodyMetrics`
/// accessor and `View.markdownBodyMetrics(_:)` modifier are public.
/// The key stays internal so it isn't re-exported as API surface.
struct MarkdownBodyMetricsKey: EnvironmentKey {
    static let defaultValue: MarkdownBodyMetrics = .default
}

public extension EnvironmentValues {
    var markdownBodyMetrics: MarkdownBodyMetrics {
        get { self[MarkdownBodyMetricsKey.self] }
        set { self[MarkdownBodyMetricsKey.self] = newValue }
    }
}

public extension View {
    /// Inject markdown body metrics for this subtree. Hosts with their
    /// own text-scale knob (Chat's appearance slider) call this at the
    /// same composition boundary as `.superTheme(_:)`; hosts that render
    /// content at the default reading size omit it.
    func markdownBodyMetrics(_ metrics: MarkdownBodyMetrics) -> some View {
        environment(\.markdownBodyMetrics, metrics)
    }
}
