import Foundation
import Testing
@testable import Chat

/// Tests for `SettingsMemoryPane.decideCommit(editingId:target:draft:)` —
/// the pure decision function that drives the pane's per-row commit
/// flow. Covers the simple happy paths plus the A→B-tap corruption
/// regression the round-2 fix missed (clearing the edit state is gated,
/// but committing also has to be).
@Suite("SettingsMemoryPane commit decision")
struct SettingsMemoryPaneCommitTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func memory(id: String, text: String) -> MemoryRecord {
        MemoryRecord(id: id, text: text, createdAt: Self.baseDate, updatedAt: Self.baseDate)
    }

    @Test func editingThisRowAndDraftDiffersFiresUpdate() {
        let target = memory(id: "A", text: "old")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: "A", target: target, draft: "new"
        )
        #expect(decision.clearsEditState == true)
        #expect(decision.update == SettingsMemoryPane.PendingUpdate(id: "A", text: "new"))
    }

    @Test func editingThisRowButDraftUnchangedClearsWithoutUpdate() {
        let target = memory(id: "A", text: "same")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: "A", target: target, draft: "same"
        )
        #expect(decision.clearsEditState == true)
        #expect(decision.update == nil)
    }

    @Test func editingThisRowButDraftEmptyClearsWithoutUpdate() {
        let target = memory(id: "A", text: "keep me")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: "A", target: target, draft: "   \n  "
        )
        #expect(decision.clearsEditState == true)
        #expect(decision.update == nil)
    }

    @Test func editingThisRowTrimsSurroundingWhitespace() {
        let target = memory(id: "A", text: "old")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: "A", target: target, draft: "  new value  "
        )
        #expect(decision.update == SettingsMemoryPane.PendingUpdate(id: "A", text: "new value"))
    }

    @Test func editingThisRowButDraftDiffersOnlyInWhitespaceSkipsUpdate() {
        let target = memory(id: "A", text: "stable")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: "A", target: target, draft: "  stable  "
        )
        #expect(decision.clearsEditState == true)
        #expect(decision.update == nil)
    }

    /// Regression for PR #72 round-5: A→B row tap previously left
    /// `editingId = B` and `draft = B.text` while A's stale onChange
    /// fired `commitEdit(for: A)`. The decision must skip BOTH the
    /// state clear and the update so A doesn't get overwritten with
    /// B's text.
    @Test func editingDifferentRowSkipsBothClearAndUpdate() {
        let target = memory(id: "A", text: "A original")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: "B", target: target, draft: "B original"
        )
        #expect(decision.clearsEditState == false)
        #expect(decision.update == nil)
    }

    @Test func noActiveEditingTargetSkipsBothClearAndUpdate() {
        // Defensive: if a stray onChange fires after the edit state has
        // already cleared (editingId = nil), don't reanimate it.
        let target = memory(id: "A", text: "stored")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: nil, target: target, draft: "would-be edit"
        )
        #expect(decision.clearsEditState == false)
        #expect(decision.update == nil)
    }
}
