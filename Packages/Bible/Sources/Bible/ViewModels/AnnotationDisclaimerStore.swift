import Foundation

public protocol AnnotationDisclaimerStore: Sendable {
    var isAcknowledged: Bool { get }
    func setAcknowledged(_ value: Bool)
}

// UserDefaults is thread-safe although this toolchain does not model its Sendable conformance.
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
