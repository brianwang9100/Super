import Foundation

@testable import Chat

actor FakeWebSearchPolicyReceiver: WebSearchPolicyReceiver {
    private var calls: [Bool] = []

    func setAskBeforeSearching(_ enabled: Bool) async {
        calls.append(enabled)
    }

    func received() -> [Bool] { calls }
}
