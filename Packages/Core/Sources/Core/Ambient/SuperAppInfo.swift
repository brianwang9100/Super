import Foundation

/// Prefer CFBundleDisplayName for the visible brand; CFBundleName may be a technical binary name.
public struct SuperAppInfo: Sendable, Equatable {
    public let bundleName: String
    public let version: String
    public let build: String

    public init(bundleName: String, version: String, build: String) {
        self.bundleName = bundleName
        self.version = version
        self.build = build
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> SuperAppInfo {
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Super"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return SuperAppInfo(bundleName: name, version: version, build: build)
    }
}
