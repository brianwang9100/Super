import MarkdownUI
import SwiftUI

/// Thin wrapper around `MarkdownUI.Markdown` that pulls the active
/// `SuperTheme` from `@Environment` and applies the matching
/// MarkdownUI theme + Splash-driven code blocks.
///
/// Used by ``AssistantMessageView``, ``ThinkingBlockView``, and
/// ``CompactionBannerView`` so all assistant prose is rendered against
/// the same palette and block chrome.
///
/// The MarkdownUI `Theme` is built once per `(SuperTheme, BodyStyle)`
/// and cached in `@State` so re-renders (e.g. after a transcript
/// refresh) don't pay the rebuild cost on every body invocation.
/// Re-keyed via `.task(id:)` whenever theme or body style changes.
struct MarkdownText: View {
    let text: String
    /// Optional override for the default text style — `ThinkingBlockView`
    /// uses this to italicize and re-color the body without forking the
    /// whole theme builder.
    let bodyStyleOverride: BodyStyle?

    @Environment(\.superTheme) private var theme
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
            .markdownTheme(cachedTheme ?? theme.markdownTheme(bodyStyle: bodyStyleOverride))
            // Selection lets the user copy a partial run from a code
            // block or a sentence from prose without invoking the
            // full-message Copy button.
            .textSelection(.enabled)
            .task(id: themeKey) {
                cachedTheme = theme.markdownTheme(bodyStyle: bodyStyleOverride)
            }
    }

    /// Cache key combines the SuperTheme value with the body-style
    /// override so a thinking trace doesn't reuse a cached banner theme
    /// (and vice versa) when both render in the same view tree.
    private var themeKey: String {
        "\(theme.id.rawValue):\(bodyStyleOverride.map(String.init(describing:)) ?? "default")"
    }
}
