import MarkdownUI
import SwiftUI

/// Hosts inject markdownBodyMetrics for text scaling; the default uses the shared reading body.
public struct MarkdownText: View {
    let text: String
    let bodyStyleOverride: BodyStyle?
    // Partial cleanup is for streaming; persisted content bypasses it.
    let treatAsPartial: Bool

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.markdownBodyMetrics) private var metrics
    @Environment(\.markdownBibleCitationPolicy) private var bibleCitationPolicy
    @State private var cachedTheme: MarkdownUI.Theme?

    public init(_ text: String, bodyStyleOverride: BodyStyle? = nil, treatAsPartial: Bool = false) {
        self.text = text
        self.bodyStyleOverride = bodyStyleOverride
        self.treatAsPartial = treatAsPartial
    }

    /// Autocloses partial Markdown before applying the host's citation policy.
    /// Recomputed for each streaming update; previews can render citations as inert labels.
    var _resolvedText: String {
        let autoclosed = treatAsPartial ? MarkdownAutocloser.close(text) : text
        return bibleCitationPolicy.resolve(autoclosed)
    }

    public enum BodyStyle: Equatable, Sendable {
        case thinking
        case banner
    }

    public var body: some View {
        // Build inline before the task primes the cache.
        Markdown(_resolvedText)
            .markdownTheme(cachedTheme ?? theme.markdownTheme(
                bodyStyle: bodyStyleOverride,
                metrics: metrics,
                readingFamily: typography.readingFamily
            ))
            .textSelection(.enabled)
            .task(id: themeKey) {
                cachedTheme = nil
                cachedTheme = theme.markdownTheme(
                    bodyStyle: bodyStyleOverride,
                    metrics: metrics,
                    readingFamily: typography.readingFamily
                )
            }
    }

    // Round scale in the cache key to absorb floating-point noise; spacing derives from scale.
    private var themeKey: String {
        let style: String = switch bodyStyleOverride {
        case .thinking: "thinking"
        case .banner: "banner"
        case .none: "default"
        }
        let scale = String(format: "%.3f", metrics.fontScale)
        let face = typography.readingFamily ?? "system"
        return "\(theme.id.rawValue):\(style):\(scale):\(face)"
    }
}
