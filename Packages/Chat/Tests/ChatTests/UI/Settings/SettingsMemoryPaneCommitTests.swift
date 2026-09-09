import Foundation
import Testing
@testable import Chat

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

    /// A stale commit for A may see B selected with B text. Skip both clearing
    /// and writing or switching rows overwrites A with B.
    @Test func editingDifferentRowSkipsBothClearAndUpdate() {
        let target = memory(id: "A", text: "A original")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: "B", target: target, draft: "B original"
        )
        #expect(decision.clearsEditState == false)
        #expect(decision.update == nil)
    }

    @Test func noActiveEditingTargetSkipsBothClearAndUpdate() {
        let target = memory(id: "A", text: "stored")
        let decision = SettingsMemoryPane.decideCommit(
            editingId: nil, target: target, draft: "would-be edit"
        )
        #expect(decision.clearsEditState == false)
        #expect(decision.update == nil)
    }
}
