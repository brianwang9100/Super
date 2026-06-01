import Foundation
import Testing
import WebKit
@testable import Chat

/// Unit tests for the pure policy backing `GeminiSearchSuggestionsView` — the
/// height clamp and the navigation decision. The live `WKWebView` itself is
/// verified by container layout + manual render (per the web-search spec §0 #8:
/// a `WKWebView` doesn't snapshot deterministically), so the testable surface is
/// this toolkit-free logic.
@Suite("GeminiSearchSuggestions")
@MainActor
struct GeminiSearchSuggestionsTests {
    // MARK: - Height clamp

    @Test func clampHeightHonorsBounds() {
        #expect(GeminiSearchSuggestions.clampHeight(44) == 44)
        // Below the floor clamps up; above the ceiling clamps down.
        #expect(GeminiSearchSuggestions.clampHeight(4) == GeminiSearchSuggestions.minHeight)
        #expect(GeminiSearchSuggestions.clampHeight(10_000) == GeminiSearchSuggestions.maxHeight)
    }

    @Test func clampHeightFallsBackForNonFiniteOrEmpty() {
        #expect(GeminiSearchSuggestions.clampHeight(0) == GeminiSearchSuggestions.minHeight)
        #expect(GeminiSearchSuggestions.clampHeight(-20) == GeminiSearchSuggestions.minHeight)
        // Non-finite values (NaN / ±infinity) fail the `isFinite` guard and
        // fall back to the floor rather than the ceiling.
        #expect(GeminiSearchSuggestions.clampHeight(.nan) == GeminiSearchSuggestions.minHeight)
        #expect(GeminiSearchSuggestions.clampHeight(.infinity) == GeminiSearchSuggestions.minHeight)
    }

    // MARK: - Navigation policy

    @Test func initialDocumentLoadIsAllowed() {
        // The `loadHTMLString` document is an `.other` navigation; only the
        // first one (the initial load) is permitted.
        let decision = GeminiSearchSuggestions.decide(
            navigationType: .other,
            url: URL(string: "about:blank"),
            isInitialLoad: true
        )
        #expect(decision == .allow)
    }

    @Test func subsequentNonUserNavigationIsCancelled() {
        // A later `.other` navigation (a redirect/injected nav, not a user tap)
        // must be blocked so a BYOK proxy can't drive the web view.
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
        // A custom-scheme link (e.g. injected `app://`/`tel:`) is not opened.
        let decision = GeminiSearchSuggestions.decide(
            navigationType: .linkActivated,
            url: URL(string: "tel:5551234"),
            isInitialLoad: false
        )
        #expect(decision == .cancel)
    }
}
