import MarkdownUI
import SwiftUI

/// Thin wrapper around `MarkdownUI.Markdown` that pulls the active
/// `SuperTheme` from `@Environment` and applies the matching
/// MarkdownUI theme + Splash-driven code blocks.
///
/// Used by ``AssistantMessageView``, ``ThinkingBlockView``, and
/// ``CompactionBannerView`` so all assistant prose is rendered against
/// the same palette and block chrome.
struct MarkdownText: View {
    let text: String
    /// Optional override for the default text style — `ThinkingBlockView`
    /// uses this to italicize and re-color the body without forking the
    /// whole theme builder.
    let bodyStyleOverride: BodyStyle?

    @Environment(\.superTheme) private var theme

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
        Markdown(text)
            .markdownTheme(theme.markdownTheme())
            .markdownTextStyle(\.text) {
                ForegroundColor(foregroundColor)
                FontSize(fontSize)
                if italic {
                    FontStyle(.italic)
                }
            }
    }

    private var foregroundColor: Color {
        switch bodyStyleOverride {
        case .thinking, .banner: return theme.inkSoft
        case .none:              return theme.ink
        }
    }

    private var fontSize: CGFloat {
        switch bodyStyleOverride {
        case .banner:   return 13
        case .thinking: return 13
        case .none:     return 15
        }
    }

    private var italic: Bool {
        bodyStyleOverride == .thinking
    }
}
