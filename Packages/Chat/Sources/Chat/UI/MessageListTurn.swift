import Foundation

/// Stable rendering unit beginning at a user message. Assistant/tool rounds
/// share its identity as they grow, persist, and become conversation history.
struct MessageListTurn: Identifiable, Equatable {
    let id: String
    var items: [MessageList.Item]

    static func group(_ items: [MessageList.Item]) -> [Self] {
        var turns: [Self] = []
        for item in items {
            if case .userBubble = item {
                turns.append(Self(id: item.id, items: [item]))
            } else if turns.isEmpty {
                turns.append(Self(id: item.id, items: [item]))
            } else {
                turns[turns.count - 1].items.append(item)
            }
        }
        return turns
    }
}
