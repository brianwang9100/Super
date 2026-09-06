import Testing
@testable import Bible

/// Protects saved-key masking, replacement, and draft cleanup without reading a Keychain secret.
@Suite("Narration key draft")
struct NarrationKeyDraftTests {
    @Test func savedKeyShowsOnlySyntheticBullets() {
        let draft = NarrationKeyDraft(hasSavedKey: true)
        #expect(draft.value == String(repeating: "•", count: 12))
        #expect(draft.isPlaceholder)
        #expect(draft.replacement.isEmpty)
    }

    @Test func focusingPlaceholderStartsAnEmptyReplacement() {
        var draft = NarrationKeyDraft(hasSavedKey: true)
        draft.beginEditing()
        #expect(draft.value.isEmpty)
        #expect(!draft.isPlaceholder)
        #expect(draft.replacement.isEmpty)
        draft.value = "new-key"
        draft.beginEditing()
        #expect(draft.replacement == "new-key")
    }

    @Test func pasteCanReplacePlaceholderWithoutFocusing() {
        var draft = NarrationKeyDraft(hasSavedKey: true)
        draft.value = "  replacement-key\n"
        #expect(!draft.isPlaceholder)
        #expect(draft.replacement == "replacement-key")
    }

    @Test func clearingDraftDiscardsEnteredKey() {
        var draft = NarrationKeyDraft(hasSavedKey: false)
        #expect(draft.value.isEmpty)
        draft.value = "entered-key"
        draft.clear()
        #expect(draft.replacement.isEmpty)
        #expect(!draft.isPlaceholder)
    }
}
