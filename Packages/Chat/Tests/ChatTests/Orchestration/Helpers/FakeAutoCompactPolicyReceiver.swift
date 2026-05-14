import Foundation

@testable import Chat

/// Captures every `setAutoCompactPolicy(enabled:threshold:)` call so a
/// test can assert that `SettingsViewModel`'s toggle/slider mutators
/// forwarded the new policy into the orchestration layer. Lives in the
/// test target so production code can't accidentally pass a no-op
/// receiver — `SettingsViewModel`'s init is required-non-optional
/// precisely to keep the composition root honest.
///
/// Doubles as the no-op default for tests that don't care about the
/// fan-out (e.g. snapshot tests, persistence tests) — they construct one
/// and never read `received()`.
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
