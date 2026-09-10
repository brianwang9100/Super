import Testing
@testable import Chat

@Suite("MessageList turns")
struct MessageListTurnTests {
    @Test("each user starts a stable turn; assistant and banner rows remain in order")
    func stableTurns() {
        let user = MessageList.Item.userBubble(id: "u1", text: "First", references: [])
        let banner = MessageList.Item.compactionBanner(id: "b1", summary: "Summary")
        let next = MessageList.Item.userBubble(id: "u2", text: "Next", references: [])
        let before = MessageListTurn.group([user, banner])
        let after = MessageListTurn.group([user, banner, next])
        #expect(before == [after[0]])
        #expect(after.map(\.id) == ["u1", "u2"])
        #expect(after.flatMap(\.items) == [user, banner, next])
    }

    @Test("empty and leading non-user history remain renderable")
    func leadingHistory() {
        let banner = MessageList.Item.compactionBanner(id: "b1", summary: "Summary")
        #expect(MessageListTurn.group([]).isEmpty)
        #expect(MessageListTurn.group([banner]).flatMap(\.items) == [banner])
    }
}
