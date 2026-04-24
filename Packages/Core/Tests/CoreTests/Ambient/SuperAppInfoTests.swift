import Testing
import Foundation
@testable import Core

/// Tests for `SuperAppInfo` initialization and bundle-fallback behavior.
@Suite("SuperAppInfo")
struct SuperAppInfoTests {
    @Test func initStoresAllFields() {
        let info = SuperAppInfo(bundleName: "Super", version: "1.2.3", build: "42")
        #expect(info.bundleName == "Super")
        #expect(info.version == "1.2.3")
        #expect(info.build == "42")
    }

    @Test func fromBundleFallsBackForEmptyBundle() {
        let info = SuperAppInfo.fromBundle(Bundle(for: BundleAnchor.self))
        #expect(!info.bundleName.isEmpty)
    }
}

private final class BundleAnchor {}
