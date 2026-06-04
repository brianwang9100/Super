import SwiftUI
import WebKit

/// Pure (UI-toolkit-free) policy for the Gemini Search-Suggestions web view, so
/// the height + navigation rules are unit-testable without a live `WKWebView`.
enum GeminiSearchSuggestions {
    /// Lower/upper bounds for the rendered strip. Google's suggestion chips are
    /// a single short row (~40–56pt); clamp the measured `scrollHeight` so a
    /// mis-measured or empty document can't collapse the row away or let an
    /// unexpected payload grow unbounded.
    static let minHeight: CGFloat = 28
    static let maxHeight: CGFloat = 120

    /// Clamp a measured `document.body.scrollHeight` into the display range,
    /// falling back to `minHeight` for a non-finite or non-positive value.
    static func clampHeight(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite, raw > 0 else { return minHeight }
        return min(max(raw, minHeight), maxHeight)
    }

    /// What to do with a navigation the web view is about to perform.
    enum Navigation: Equatable {
        /// Let the web view proceed (the initial `loadHTMLString` document).
        case allow
        /// Block the in-view navigation (non-user-initiated, or a non-web link).
        case cancel
        /// Cancel the in-view navigation and open the URL externally instead.
        case openExternally(URL)
    }

    /// Decide how to handle a navigation. The chips are anchors to
    /// `google.com/search?…`; a user tap (`.linkActivated`) to an http(s) URL
    /// opens externally. The only in-view navigation allowed is the initial
    /// document load; everything else (redirects, injected navigations) is
    /// blocked so a BYOK-configured proxy can't drive the web view somewhere.
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

/// Renders Gemini's mandatory "Google Search Suggestions" HTML
/// (`searchEntryPoint.renderedContent`) **unmodified** beneath a grounded
/// Gemini response, per Google's grounding display terms. Unlike the
/// collapsible sources pill, this strip is always visible whenever the grounded
/// reply is shown.
///
/// The fragment is HTML + inline CSS (deep-linking chips, with its own
/// light/dark variants), rendered in a constrained `WKWebView`: scrolling and
/// zoom are disabled, the background is transparent, and the height is measured
/// from the document after load. Taps on chips open externally via `openURL`;
/// no other navigation is permitted. The HTML itself is never altered — only
/// the container is sized.
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

/// iOS `WKWebView` host for the suggestions HTML.
private struct SuggestionsWebView: UIViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> SuggestionsWebCoordinator {
        SuggestionsWebCoordinator(measuredHeight: $measuredHeight, onOpenURL: onOpenURL)
    }

    /// Configuration with web-content JavaScript disabled: the suggestion chips
    /// are plain anchors, so no page script needs to run. The host's
    /// `evaluateJavaScript` height probe is app-initiated and unaffected. This is
    /// defense-in-depth — a BYOK-configured proxy can't inject runnable script.
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

/// macOS `WKWebView` host for the suggestions HTML.
private struct SuggestionsWebView: NSViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> SuggestionsWebCoordinator {
        SuggestionsWebCoordinator(measuredHeight: $measuredHeight, onOpenURL: onOpenURL)
    }

    /// Configuration with web-content JavaScript disabled (see the iOS host).
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
/// Shared navigation delegate: measures the rendered height after load and
/// applies ``GeminiSearchSuggestions/decide(navigationType:url:isInitialLoad:)``
/// to every navigation. `@MainActor` so the compiler enforces that its
/// `WKWebView` + `Binding` access stays on the main actor (the delegate
/// callbacks already arrive there).
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

    /// Load `html`, recording it so an unchanged `update*View` pass doesn't
    /// reload, and arming the next navigation as the (allowed) initial load.
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
