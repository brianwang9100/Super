import Core
import SwiftUI

/// Bible-side environment for rendering Core's `MarkdownText`: one modifier
/// that every Bible surface hosting LLM markdown applies at its root.
///
/// It installs the two things a Bible markdown host must not forget:
///
/// 1. **Font-scale projection** — `MarkdownText` scales off
///    `\.markdownBodyMetrics`, whose environment default is a fixed 1.0×.
///    The slider is a *global* size control, so the modifier projects
///    `typography.fontScale` onto the renderer; without it a surface
///    compiles clean but silently stops tracking the slider.
/// 2. **Citation-link routing** — the renderer auto-linkifies scripture
///    citations into `super://bible/...` URLs. Taps route to `openLink`
///    in-process. A `super://` URL that *fails* to parse (an
///    LLM-hand-authored malformed link the linkifier passed through
///    verbatim) is **discarded**, not handed to the system — bouncing
///    our own custom scheme to `UIApplication.open` would foreground
///    whichever app last registered `super://` (the documented
///    SuperOS/SuperBible dual-install collision) or no-op re-enter this
///    one. Genuine external URLs (`https://...`) still fall through to
///    the system so they open in Safari.
private struct BibleMarkdownRendering: ViewModifier {
    @Environment(\.superTypography) private var typography

    let openLink: (BibleDeepLink) -> Void

    func body(content: Content) -> some View {
        content
            .markdownBodyMetrics(MarkdownBodyMetrics(fontScale: typography.fontScale))
            .environment(\.openURL, OpenURLAction { url in
                if let link = BibleDeepLink(url: url) {
                    openLink(link)
                    return .handled
                }
                // Our scheme but unparseable — swallow the dud tap.
                if url.scheme == BibleDeepLink.urlScheme {
                    return .discarded
                }
                return .systemAction
            })
    }
}

extension View {
    /// Apply at the root of any Bible surface that renders `MarkdownText`
    /// (the annotation sheet today; notes or overview panes next), so the
    /// markdown tracks the global font-scale slider and its linkified
    /// citations navigate the reader via `openLink`.
    func bibleMarkdownRendering(openLink: @escaping (BibleDeepLink) -> Void) -> some View {
        modifier(BibleMarkdownRendering(openLink: openLink))
    }
}
