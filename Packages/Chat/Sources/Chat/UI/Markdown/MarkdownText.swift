import Core
import MarkdownUI
import SwiftUI

/// Thin wrapper around `MarkdownUI.Markdown` that pulls the active
/// `SuperTheme` from `@Environment` and applies the matching
/// MarkdownUI theme + Splash-driven code blocks.
///
/// Used by ``AssistantMessage``, ``ThinkingBlock``, and
/// ``CompactionBanner`` so all assistant prose is rendered against
/// the same palette and block chrome.
///
/// The MarkdownUI `Theme` is built once per `(SuperTheme, BodyStyle)`
/// and cached in `@State` so re-renders (e.g. after a transcript
/// refresh) don't pay the rebuild cost on every body invocation.
/// Re-keyed via `.task(id:)` whenever theme or body style changes.
struct MarkdownText: View {
    let text: String
    /// Optional override for the default text style — `ThinkingBlock`
    /// uses this to italicize and re-color the body without forking the
    /// whole theme builder.
    let bodyStyleOverride: BodyStyle?

    @Environment(\.superTheme) private var theme
    @Environment(\.chatAppearance) private var appearance
    @State private var cachedTheme: MarkdownUI.Theme?

    init(_ text: String, bodyStyleOverride: BodyStyle? = nil) {
        self.text = text
        self.bodyStyleOverride = bodyStyleOverride
    }

    /// Per-call-site overrides for the default `Theme.text` style.
    /// Centralized into this enum so the three known consumers share a
    /// single definition rather than each forking their own theme builder.
    enum BodyStyle: Equatable {
        /// Italic + softer ink for thinking traces.
        case thinking
        /// Smaller body for the compaction banner — sits under a row of
        /// dividers in the design and doesn't carry headings.
        case banner
    }

    var body: some View {
        // First render before `.task` fires uses an inline build; the
        // task primes the cache so subsequent renders skip the rebuild.
        Markdown(text)
            .markdownTheme(cachedTheme ?? theme.markdownTheme(bodyStyle: bodyStyleOverride, appearance: appearance))
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
                cachedTheme = theme.markdownTheme(bodyStyle: bodyStyleOverride, appearance: appearance)
            }
    }

    /// Cache key combines theme, body-style override, and the font
    /// scale so a thinking trace doesn't reuse a cached banner theme
    /// (and vice versa), and so a font-scale change invalidates the
    /// cached MarkdownUI theme. Font scale is formatted to a fixed
    /// precision so two arithmetically-equal but binarily-different
    /// `Double`s map to the same key. Spacing is derived from
    /// `fontScale` inside `ChatAppearance`, so the scale alone is a
    /// sufficient invalidation signal.
    private var themeKey: String {
        let style: String = switch bodyStyleOverride {
        case .thinking: "thinking"
        case .banner: "banner"
        case .none: "default"
        }
        let scale = String(format: "%.3f", appearance.fontScale)
        return "\(theme.id.rawValue):\(style):\(scale)"
    }
}
