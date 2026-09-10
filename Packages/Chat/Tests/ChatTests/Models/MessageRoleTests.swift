import Core
import Foundation
import Testing
@testable import Chat

@Suite("MessageRole")
struct MessageRoleTests {

    @Test func rawValuesMatchOnDiskFormat() {
        #expect(MessageRole.allCases.map(\.rawValue) == ["user", "assistant", "system", "tool"])
    }

    @Test func asLLMRoleMapsEachCaseDirectly() {
        #expect(MessageRole.user.asLLMRole() == .user)
        #expect(MessageRole.assistant.asLLMRole() == .assistant)
        #expect(MessageRole.system.asLLMRole() == .system)
        #expect(MessageRole.tool.asLLMRole() == .tool)
    }

    @Test func initFromLLMRoleMapsEachCaseDirectly() {
        #expect(MessageRole(.user) == .user)
        #expect(MessageRole(.assistant) == .assistant)
        #expect(MessageRole(.system) == .system)
        #expect(MessageRole(.tool) == .tool)
    }
}
