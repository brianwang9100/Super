import SwiftUI
import WebKit

enum GeminiSearchSuggestions {
    // Bound malformed height probes without hiding the required suggestions or allowing unbounded content.
    static let minHeight: CGFloat = 28
    static let maxHeight: CGFloat = 120

    static func clampHeight(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite, raw > 0 else { return minHeight }
        return min(max(raw, minHeight), maxHeight)
    }

    enum Navigation: Equatable {
        case allow
        case cancel
        case openExternally(URL)
    }

    /// Allow only the initial in-view load. User-activated web links open externally;
    /// block other navigation so provider proxies cannot redirect the embedded view.
    static func decide(
        navigationType: WKNavigationType,
        url: URL?,
        isInitialLoad: Bool
    ) -> Navigation {
        if navigationType == .linkActivated {
            if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return .openExternally(url)
            }
            return .cancel
        }
        return isInitialLoad ? .allow : .cancel
    }
}

/// Google requires this grounding HTML unmodified and always visible.
/// Resize only its container; open suggestion links externally.
struct GeminiSearchSuggestionsView: View {
    let html: String
    @State private var measuredHeight: CGFloat = GeminiSearchSuggestions.minHeight
    @Environment(\.openURL) private var openURL

    var body: some View {
        SuggestionsWebView(
            html: html,
            measuredHeight: $measuredHeight,
            onOpenURL: { openURL($0) }
        )
        .frame(height: measuredHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Google Search Suggestions")
    }
}

#if canImport(UIKit)
import UIKit

private struct SuggestionsWebView: UIViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> SuggestionsWebCoordinator {
        SuggestionsWebCoordinator(measuredHeight: $measuredHeight, onOpenURL: onOpenURL)
    }

    /// Suggestion anchors need no page scripts. Disable proxy-supplied JavaScript;
    /// app-initiated evaluateJavaScript height measurement still works.
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return config
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: SuggestionsWebView.configuration())
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        if context.coordinator.loadedHTML != html {
            context.coordinator.load(html, into: webView)
        }
    }
}
#elseif canImport(AppKit)
import AppKit

private struct SuggestionsWebView: NSViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> SuggestionsWebCoordinator {
        SuggestionsWebCoordinator(measuredHeight: $measuredHeight, onOpenURL: onOpenURL)
    }

    // Same page-script restriction as the iOS host.
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return config
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: SuggestionsWebView.configuration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        if context.coordinator.loadedHTML != html {
            context.coordinator.load(html, into: webView)
        }
    }
}
#endif

#if canImport(UIKit) || canImport(AppKit)
@MainActor
final class SuggestionsWebCoordinator: NSObject, WKNavigationDelegate {
    private let measuredHeight: Binding<CGFloat>
    var onOpenURL: (URL) -> Void
    private(set) var loadedHTML: String?
    private var didStartInitialLoad = false

    init(measuredHeight: Binding<CGFloat>, onOpenURL: @escaping (URL) -> Void) {
        self.measuredHeight = measuredHeight
        self.onOpenURL = onOpenURL
    }

    func load(_ html: String, into webView: WKWebView) {
        didStartInitialLoad = false
        loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body.scrollHeight") { [measuredHeight] value, _ in
            let raw = (value as? CGFloat) ?? (value as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
            let clamped = GeminiSearchSuggestions.clampHeight(raw)
            measuredHeight.wrappedValue = clamped
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let isInitialLoad = !didStartInitialLoad
        let decision = GeminiSearchSuggestions.decide(
            navigationType: navigationAction.navigationType,
            url: navigationAction.request.url,
            isInitialLoad: isInitialLoad
        )
        switch decision {
        case .allow:
            didStartInitialLoad = true
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally(let url):
            decisionHandler(.cancel)
            onOpenURL(url)
        }
    }
}
#endif
