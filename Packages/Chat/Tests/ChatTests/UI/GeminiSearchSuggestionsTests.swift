import Foundation
import Testing
import WebKit
@testable import Chat

// WKWebView rendering is nondeterministic; this suite checks policy and geometry only.
@Suite("GeminiSearchSuggestions")
@MainActor
struct GeminiSearchSuggestionsTests {
    // MARK: - Height clamp

    @Test func clampHeightHonorsBounds() {
        #expect(GeminiSearchSuggestions.clampHeight(44) == 44)
        #expect(GeminiSearchSuggestions.clampHeight(4) == GeminiSearchSuggestions.minHeight)
        #expect(GeminiSearchSuggestions.clampHeight(10_000) == GeminiSearchSuggestions.maxHeight)
    }

    @Test func clampHeightFallsBackForNonFiniteOrEmpty() {
        #expect(GeminiSearchSuggestions.clampHeight(0) == GeminiSearchSuggestions.minHeight)
        #expect(GeminiSearchSuggestions.clampHeight(-20) == GeminiSearchSuggestions.minHeight)
        #expect(GeminiSearchSuggestions.clampHeight(.nan) == GeminiSearchSuggestions.minHeight)
        #expect(GeminiSearchSuggestions.clampHeight(.infinity) == GeminiSearchSuggestions.minHeight)
    }

    // MARK: - Navigation policy

    @Test func initialDocumentLoadIsAllowed() {
        // loadHTMLString arrives as an .other navigation, so permit only the initial one.
        let decision = GeminiSearchSuggestions.decide(
            navigationType: .other,
            url: URL(string: "about:blank"),
            isInitialLoad: true
        )
        #expect(decision == .allow)
    }

    @Test func subsequentNonUserNavigationIsCancelled() {
        // Block injected navigation and redirects from provider-supplied HTML.
        let decision = GeminiSearchSuggestions.decide(
            navigationType: .other,
            url: URL(string: "https://evil.example.com"),
            isInitialLoad: false
        )
        #expect(decision == .cancel)
    }

    @Test func userTapOnWebLinkOpensExternally() {
        let url = URL(string: "https://www.google.com/search?q=mars")!
        let decision = GeminiSearchSuggestions.decide(
            navigationType: .linkActivated,
            url: url,
            isInitialLoad: false
        )
        #expect(decision == .openExternally(url))
    }

    @Test func userTapOnNonWebLinkIsCancelled() {
        let decision = GeminiSearchSuggestions.decide(
            navigationType: .linkActivated,
            url: URL(string: "tel:5551234"),
            isInitialLoad: false
        )
        #expect(decision == .cancel)
    }
}
