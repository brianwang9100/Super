import Testing
@testable import Core

@Test
func corePackageIsReachable() {
    #expect(Core.version == "0.0.1")
}
