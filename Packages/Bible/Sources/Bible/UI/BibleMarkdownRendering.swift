import Core
import SwiftUI

/// Projects app font scale into Markdown metrics and routes Bible links in-process.
/// Discard malformed super URLs: system handling could open the other installed
/// app that registered the same scheme. External URLs retain system handling.
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
                if url.scheme == BibleDeepLink.urlScheme {
                    return .discarded
                }
                return .systemAction
            })
    }
}

extension View {
    /// Apply to every Bible MarkdownText host for font scaling and citation routing.
    func bibleMarkdownRendering(openLink: @escaping (BibleDeepLink) -> Void) -> some View {
        modifier(BibleMarkdownRendering(openLink: openLink))
    }
}
