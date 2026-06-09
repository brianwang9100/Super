import Core
import Foundation
import Testing
import Todo

/// Smoke tests for the Todo module identifier and the applet's
/// `MiniApplet` conformance — guards a future rename of `appletID`
/// (which would break persisted backdrop selection) and a packaging
/// regression that would drop `SystemPrompt.md` from the bundle.
@Suite("Todo module")
@MainActor
struct TodoTests {
    @Test func appletIDIsStable() {
        #expect(TodoModule.appletID == "todo")
    }

    @Test("systemPrompt loads the bundled SystemPrompt.md")
    func systemPromptLoaded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "todo-systemprompt-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let applet = TodoApplet(dependencies: try TodoDependencies.live(in: directory))
        let body = applet.systemPrompt
        // Assert structural shape rather than literal wording so the test
        // doesn't churn with every prompt edit.
        #expect(!body.isEmpty)
        #expect(body.contains("Todo applet"))
    }

    @Test("suggestedChatActions contributes non-empty Todo chat starters")
    func suggestedChatActions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "todo-actions-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let actions = TodoApplet(dependencies: try TodoDependencies.live(in: directory)).suggestedChatActions
        #expect(!actions.isEmpty)
        #expect(actions.allSatisfy { !$0.label.isEmpty && !$0.message.isEmpty })
        #expect(actions.contains { $0.label == "Add a task" })
    }
}
