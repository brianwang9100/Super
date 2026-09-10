import Core
import SwiftUI
import Testing
@testable import Bible

@Suite("BibleBookmarksApplet")
@MainActor
struct BibleBookmarksAppletTests {
    @Test("registry metadata is stable")
    func registryMetadata() {
        let applet = makeApplet()
        #expect(applet.appletID == "bookmarks")
        #expect(BibleBookmarksApplet.appletID == "bookmarks")
        #expect(applet.displayName == "Bookmarks")
    }

    @Test("the applet contributes no LLM briefing")
    func emptySystemPrompt() {
        // The registry omits empty briefings from the LLM prompt.
        let applet = makeApplet()
        #expect(applet.systemPrompt.isEmpty)
        #expect(applet.suggestedChatActions.isEmpty)
    }

    @Test("BibleApplet hands its database context over to the bookmarks applet")
    func makeBookmarksApplet() {
        let bibleApplet = BibleApplet(
            viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader())
        )
        let applet = bibleApplet.makeBookmarksApplet()
        #expect(applet.appletID == "bookmarks")
        _ = applet.rootView()
    }

    private func makeApplet() -> BibleBookmarksApplet {
        BibleBookmarksApplet(databaseContext: nil)
    }
}
