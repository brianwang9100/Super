import Foundation

@testable import Chat

/// Captures every `setAskBeforeSearching(_:)` call so a test can assert
/// that `SettingsViewModel`'s Search-pane toggle forwarded the new gate
/// into the orchestration layer. Lives in the test target so production
/// code can't accidentally pass a no-op receiver — `SettingsViewModel`'s
/// init is required-non-optional precisely to keep the composition root
/// honest. Mirrors `FakeAutoCompactPolicyReceiver`.
///
/// Doubles as the no-op default for tests that don't care about the
/// fan-out (e.g. snapshot tests, persistence tests) — they construct one
/// and never read `received()`.
actor FakeWebSearchPolicyReceiver: WebSearchPolicyReceiver {
    private var calls: [Bool] = []

    func setAskBeforeSearching(_ enabled: Bool) async {
        calls.append(enabled)
    }

    func received() -> [Bool] { calls }
}
