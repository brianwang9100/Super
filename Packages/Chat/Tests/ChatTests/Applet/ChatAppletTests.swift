import Core
import SwiftUI
import Testing
@testable import Chat

/// Smoke checks for `ChatApplet`. The conformance exists primarily as a
/// reference / fixture (Chat is not registered as a backdrop applet in
/// production — `AppShell` omits it deliberately) but `AppBootstrap`
/// reads `ChatApplet().systemPrompt` to load the bundled chat-assistant
/// briefing fed to `ContextAssembler` on every turn. A regression that
/// silently drops `Resources/DefaultSystemPrompt.md` from the Chat
/// Swift Package Manager (SPM) bundle would surface as an empty leading
/// system block in production with no other test failing — these
/// assertions are the tripwire.
@Suite("ChatApplet conformance")
@MainActor
struct ChatAppletTests {
    @Test("appletID is stable")
    func appletIDIsStable() {
        #expect(ChatApplet.appletID == "chat")
        #expect(ChatApplet().appletID == "chat")
    }

    @Test("displayName is 'Chat'")
    func displayName() {
        #expect(ChatApplet().displayName == "Chat")
    }

    @Test("systemPrompt loads the bundled DefaultSystemPrompt.md")
    func systemPromptLoaded() {
        let body = ChatApplet().systemPrompt
        // Asserts the resource is bundled (and non-empty). Packaging
        // regression — `Package.swift` flips to `.copy` without
        // `subdirectory:`, the file is removed, etc. — fails here
        // rather than silently shipping an empty leading system
        // block in production.
        #expect(!body.isEmpty)
        // Structural sanity check on the new header preamble — guards
        // against a future edit that accidentally strips the section
        // explaining the `## <Applet> applet` convention to the Large
        // Language Model (LLM).
        #expect(body.contains("## Reading the sections that follow"))
    }
}
