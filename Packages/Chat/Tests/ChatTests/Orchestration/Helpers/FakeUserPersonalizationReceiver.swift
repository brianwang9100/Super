import Foundation

@testable import Chat

/// Captures every `setUserPersonalization(_:)` call so a test can assert
/// that `SettingsViewModel.setUserPersonalization(_:)` forwarded the
/// value into the orchestration layer. Lives in the test target so
/// production code can't accidentally pass a no-op receiver —
/// `SettingsViewModel`'s init is required-non-optional precisely to
/// keep the composition root honest.
///
/// Doubles as the no-op default for tests that don't care about the
/// fan-out (e.g. snapshot tests, persistence tests) — they construct one
/// and never read `received()`.
actor FakeUserPersonalizationReceiver: UserPersonalizationReceiver {
    private var values: [String] = []

    func setUserPersonalization(_ value: String) async {
        values.append(value)
    }

    func received() -> [String] { values }
}
