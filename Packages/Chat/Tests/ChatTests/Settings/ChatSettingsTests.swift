import Foundation
import Testing
@testable import Chat

/// Tests for `ChatSettings.default` — specifically that `systemPrompt`
/// resolves from the bundled `DefaultSystemPrompt.md` rather than a
/// hardcoded literal. The non-overriding-of-user-customization guarantee
/// is covered by `SettingsViewModelTests.loadPersistedValues`, which
/// asserts a stored prompt survives `ChatSettingsStore.load()`.
@Suite("ChatSettings")
struct ChatSettingsTests {
    @Test("default systemPrompt loads from bundled DefaultSystemPrompt.md")
    func defaultSystemPromptLoadsFromBundle() {
        let prompt = ChatSettings.default.systemPrompt
        // The bundled prompt opens with this exact phrase. If the loader
        // silently reverts to a literal, this prefix won't match.
        #expect(prompt.hasPrefix("You are Super's assistant"))
        // Sanity-check that meaningful content is present, not just the
        // opening sentence — guards against a truncated read.
        #expect(prompt.count > 500)
    }

    @Test("default systemPrompt is trimmed of surrounding whitespace")
    func defaultSystemPromptIsTrimmed() {
        let prompt = ChatSettings.default.systemPrompt
        #expect(prompt == prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
