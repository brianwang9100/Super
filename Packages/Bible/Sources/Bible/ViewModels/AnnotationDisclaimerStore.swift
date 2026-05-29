import Foundation

/// Persists the user's one-time acknowledgement of the AI-annotation
/// liability sheet.
///
/// Injected into `BibleScreenViewModel` so tests substitute an in-memory
/// double instead of touching `UserDefaults.standard`. The production
/// concrete impl writes the documented key
/// `"bible.annotations.disclaimerAcknowledged"` per spec §8.
public protocol AnnotationDisclaimerStore: Sendable {
    var isAcknowledged: Bool { get }
    func setAcknowledged(_ value: Bool)
}

/// `UserDefaults`-backed concrete implementation used in production.
///
/// The defaults instance is injectable so app targets and tests can hand
/// a suite-scoped store (`UserDefaults(suiteName:)`); the production
/// composition root uses `.standard`. `@unchecked Sendable` because
/// Apple documents `UserDefaults` as thread-safe; the Swift 6 toolchain
/// doesn't model that yet.
public struct UserDefaultsAnnotationDisclaimerStore: AnnotationDisclaimerStore, @unchecked Sendable {
    private static let key = "bible.annotations.disclaimerAcknowledged"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isAcknowledged: Bool {
        defaults.bool(forKey: Self.key)
    }

    public func setAcknowledged(_ value: Bool) {
        defaults.set(value, forKey: Self.key)
    }
}
