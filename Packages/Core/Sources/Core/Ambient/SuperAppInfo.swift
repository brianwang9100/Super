import Foundation

/// Bundle metadata for the Super app shell, read by the sidebar header and
/// About pane. Reads `CFBundleName` / `CFBundleShortVersionString` /
/// `CFBundleVersion` from the supplied bundle and falls back to safe defaults
/// when keys are missing — useful in unit tests where the test bundle has no
/// Info.plist.
public struct SuperAppInfo: Sendable, Equatable {
    public let bundleName: String
    public let version: String
    public let build: String

    public init(bundleName: String, version: String, build: String) {
        self.bundleName = bundleName
        self.version = version
        self.build = build
    }

    /// Build a value from a Bundle's Info.plist, with safe defaults for
    /// missing keys.
    public static func fromBundle(_ bundle: Bundle = .main) -> SuperAppInfo {
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Super"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return SuperAppInfo(bundleName: name, version: version, build: build)
    }
}
