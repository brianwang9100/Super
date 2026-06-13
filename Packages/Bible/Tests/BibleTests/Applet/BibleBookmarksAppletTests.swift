import Core
import SwiftUI
import Testing
@testable import Bible

/// Tests for the Bookmarks mini-applet's registry metadata and its
/// construction seam off `BibleApplet`. The applet is SuperBible-only and
/// deliberately mute toward the LLM (empty system prompt) — these pins keep
/// a future refactor from silently changing the sidebar contract.
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
        // The registry drops empty bodies, so no `## Bookmarks applet`
        // block is injected; chat actions come from the protocol default.
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
        // Root view stays constructible without a database (snapshot/preview
        // path) — the screen's @Query then falls back to its empty default.
        _ = applet.rootView()
    }

    private func makeApplet() -> BibleBookmarksApplet {
        BibleBookmarksApplet(databaseContext: nil)
    }
}
