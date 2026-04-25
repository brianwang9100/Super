import Foundation

/// Loads SSE (Server-Sent Events) fixture text from the test bundle's
/// `Fixtures/` directory. Crashes loudly on a missing file because a
/// missing fixture is a test-setup bug, not a runtime branch worth
/// recovering from.
enum FixtureLoader {
    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "Fixtures"
        ) else {
            fatalError("Fixture not found: Fixtures/\(name).txt — check Resources in Package.swift")
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
