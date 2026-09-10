#if DEBUG
import Core
import Foundation

enum DebugSearchFixture {
    static let findings = """
    Based on the latest reporting, the rover confirmed subsurface water ice \
    in Jezero crater and relayed fresh imagery this week. Sources below.
    """

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

    /// Rendered unmodified, matching Gemini's `searchEntryPoint.renderedContent` contract.
    static let suggestionsHTML = """
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1">\
    <style>html,body{margin:0;padding:0}body{font-family:-apple-system;line-height:1}\
    .c{font-size:17px;display:inline-block;padding:10px 16px;border:1px solid #ddd;\
    border-radius:20px;margin:0 8px 0 0;color:#1a73e8;text-decoration:none}</style></head>\
    <body><a class="c" href="https://www.google.com/search?q=mars+rover+news">mars rover news</a>\
    <a class="c" href="https://www.google.com/search?q=jezero+crater+water">jezero crater water</a></body></html>
    """
}
#endif
