import MarkdownUI
import SwiftUI

/// Thin wrapper around `MarkdownUI.Markdown` that pulls the active
/// `SuperTheme` from `@Environment` and applies the matching
/// MarkdownUI theme + Splash-driven code blocks.
///
/// The shared long-form-prose renderer: Chat's assistant surfaces
/// (`AssistantMessage`, `ThinkingBlock`, `CompactionBanner`) render
/// through it today; it lives in Core (rather than Chat) so other
/// applets — first up, Bible's annotation card — can adopt it without
/// violating applet isolation, and LLM prose paints against the same
/// palette, faces, and block chrome everywhere.
/// Hosts with a text-scale knob inject `\.markdownBodyMetrics`;
/// the environment default renders the 19pt reading body.
///
/// The MarkdownUI `Theme` is built once per `(SuperTheme, BodyStyle)`
/// and cached in `@State` so re-renders (e.g. after a transcript
/// refresh) don't pay the rebuild cost on every body invocation.
/// Re-keyed via `.task(id:)` whenever theme or body style changes.
public struct MarkdownText: View {
    let text: String
    /// Optional override for the default text style — Chat's
    /// `ThinkingBlock` uses this to shrink and re-color the body
    /// without forking the whole theme builder.
    let bodyStyleOverride: BodyStyle?
    /// When true, the input is routed through ``MarkdownAutocloser``
    /// before MarkdownUI parses it — closes dangling fences, strips
    /// half-written links, trims unmatched emphasis. Set by the live
    /// streaming overlay; the persisted assistant row leaves this at
    /// its default so its rendering is byte-for-byte unchanged.
    let treatAsPartial: Bool

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.markdownBodyMetrics) private var metrics
    @State private var cachedTheme: MarkdownUI.Theme?

    public init(_ text: String, bodyStyleOverride: BodyStyle? = nil, treatAsPartial: Bool = false) {
        self.text = text
        self.bodyStyleOverride = bodyStyleOverride
        self.treatAsPartial = treatAsPartial
    }

    /// Test-only seam exposing the string that will be handed to
    /// MarkdownUI — i.e. the autocloser-processed text when
    /// `treatAsPartial` is set, followed by the verse-reference
    /// linkifier that wraps Bible citations in `super://bible/...`
    /// markdown links the chat-side `OpenURLAction` interceptor can
    /// route to the Bible applet. Underscore prefix marks it as not
    /// part of the stable API, per the codebase convention for test
    /// seams (e.g. `_waitForPendingTitleTask`).
    ///
    /// Recomputes both passes on every body invocation rather than
    /// memoizing via `@State`. Streaming text changes every coalescer
    /// flush so a cache keyed on the input would always miss; both
    /// passes carry a prose-only fast path (single byte walk for the
    /// autocloser, substring presence check for the linkifier) so the
    /// dominant "no markers, no scripture" message is essentially
    /// free. Marker-rich or citation-rich inputs pay the per-render
    /// cost — known and accepted in exchange for the simpler view
    /// shape.
    var _resolvedText: String {
        let autoclosed = treatAsPartial ? MarkdownAutocloser.close(text) : text
        return BibleReferenceLinkifier.linkify(autoclosed)
    }

    /// Per-call-site overrides for the default `Theme.text` style.
    /// Centralized into this enum so the known consumers share a
    /// single definition rather than each forking their own theme builder.
    public enum BodyStyle: Equatable, Sendable {
        /// Softer ink + smaller body for thinking traces.
        case thinking
        /// Smaller body for the compaction banner — sits under a row of
        /// dividers in the design and doesn't carry headings.
        case banner
    }

    public var body: some View {
        // First render before `.task` fires uses an inline build; the
        // task primes the cache so subsequent renders skip the rebuild.
        Markdown(_resolvedText)
            .markdownTheme(cachedTheme ?? theme.markdownTheme(
                bodyStyle: bodyStyleOverride,
                metrics: metrics,
                readingFamily: typography.readingFamily
            ))
            // Selection lets the user copy a partial run from a code
            // block or a sentence from prose without invoking the
            // full-message Copy button.
            .textSelection(.enabled)
            .task(id: themeKey) {
                // Drop the stale cache synchronously before the async
                // rebuild so the next render falls through to the inline
                // fallback (which already reads the new theme/appearance)
                // instead of painting one frame against the prior cached
                // theme — visible as a flash during slider drags.
                cachedTheme = nil
                cachedTheme = theme.markdownTheme(
                    bodyStyle: bodyStyleOverride,
                    metrics: metrics,
                    readingFamily: typography.readingFamily
                )
            }
    }

    /// Cache key combines theme, body-style override, and the font
    /// scale so a thinking trace doesn't reuse a cached banner theme
    /// (and vice versa), and so a font-scale change invalidates the
    /// cached MarkdownUI theme. Font scale is formatted to a fixed
    /// precision so two arithmetically-equal but binarily-different
    /// values map to the same key. Spacing is derived from `fontScale`
    /// inside `MarkdownBodyMetrics`, so the scale alone is a
    /// sufficient invalidation signal.
    private var themeKey: String {
        let style: String = switch bodyStyleOverride {
        case .thinking: "thinking"
        case .banner: "banner"
        case .none: "default"
        }
        let scale = String(format: "%.3f", metrics.fontScale)
        // Include the reading family so a serif↔system typeface switch
        // invalidates the cached MarkdownUI theme (the body face changes).
        let face = typography.readingFamily ?? "system"
        return "\(theme.id.rawValue):\(style):\(scale):\(face)"
    }
}
