import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `MessageRole` raw values, `LLMRole` translation in both
/// directions, and round-trip totality.
@Suite("MessageRole")
struct MessageRoleTests {

    @Test func rawValuesMatchOnDiskFormat() {
        #expect(MessageRole.user.rawValue == "user")
        #expect(MessageRole.assistant.rawValue == "assistant")
        #expect(MessageRole.system.rawValue == "system")
        #expect(MessageRole.tool.rawValue == "tool")
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

    @Test func roundTripsThroughLLMRoleForEveryCase() {
        for role in MessageRole.allCases {
            #expect(MessageRole(role.asLLMRole()) == role)
        }
    }

    @Test func allCasesIsExhaustive() {
        #expect(MessageRole.allCases.count == 4)
    }
}
