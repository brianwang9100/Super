import Foundation

@testable import Chat

actor FakeAutoCompactPolicyReceiver: AutoCompactPolicyReceiver {
    struct Call: Equatable {
        let enabled: Bool
        let threshold: Double
    }

    private var calls: [Call] = []

    func setAutoCompactPolicy(enabled: Bool, threshold: Double) async {
        calls.append(Call(enabled: enabled, threshold: threshold))
    }

    func received() -> [Call] { calls }
}
