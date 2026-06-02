#if DEBUG
import Core
import Foundation

/// Canned web-search data shared by the two DEBUG search fakes:
/// `DebugLLMProvider`'s built-in "search" script (which fakes the whole
/// conversation) and `DebugWebSearchFulfiller` (which fulfills the `"debug"`
/// mock backend for a real model). One source of truth so both render the
/// same NASA/space sources + suggestions strip.
enum DebugSearchFixture {
    /// Grounded-style answer text. Reads like a real reply so the sources
    /// pill renders under a realistic message.
    static let findings = """
    Based on the latest reporting, the rover confirmed subsurface water ice \
    in Jezero crater and relayed fresh imagery this week. Sources below.
    """

    /// Three canned citations the sources pill renders + expands.
    static let citations: [SourceCitation] = [
        SourceCitation(
            id: "https://www.nasa.gov/mars-rover#0",
            title: "Perseverance confirms subsurface water ice",
            url: URL(string: "https://www.nasa.gov/mars-rover")!
        ),
        SourceCitation(
            id: "https://www.space.com/rover-update#1",
            title: "Mars rover relays new imagery from Jezero crater",
            url: URL(string: "https://www.space.com/rover-update")!
        ),
        SourceCitation(
            id: "https://www.scientificamerican.com/mars#2",
            title: "What the new Mars findings mean for the search for life",
            url: URL(string: "https://www.scientificamerican.com/mars")!
        ),
    ]

    /// Sample Google Search-Suggestions HTML, exercising the always-visible
    /// `GeminiSearchSuggestionsView` strip without a real grounded response.
    /// A minimal stand-in for Gemini's `searchEntryPoint.renderedContent`
    /// (the real payload is richer styled HTML); rendered unmodified by the
    /// strip just like the live one.
    static let suggestionsHTML = """
    <html><head><style>.c{font-family:-apple-system;font-size:14px;\
    display:inline-block;padding:6px 12px;border:1px solid #ddd;\
    border-radius:16px;margin:2px;color:#1a73e8;text-decoration:none}</style></head>\
    <body><a class="c" href="https://www.google.com/search?q=mars+rover+news">mars rover news</a>\
    <a class="c" href="https://www.google.com/search?q=jezero+crater+water">jezero crater water</a></body></html>
    """
}
#endif
