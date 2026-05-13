import Foundation

@testable import Chat

/// Captures every `setSystemPrompt(_:)` call so a test can assert that
/// `SettingsViewModel.setSystemPrompt(_:)` forwarded the value into the
/// orchestration layer. Lives in the test target so production code can't
/// accidentally pass a no-op receiver — `SettingsViewModel`'s init is
/// required-non-optional precisely to keep the composition root honest.
///
/// Doubles as the no-op default for tests that don't care about the
/// fan-out (e.g. snapshot tests, persistence tests) — they construct one
/// and never read `received()`.
actor FakeSystemPromptReceiver: SystemPromptReceiver {
    private var prompts: [String] = []

    func setSystemPrompt(_ value: String) async {
        prompts.append(value)
    }

    func received() -> [String] { prompts }
}
