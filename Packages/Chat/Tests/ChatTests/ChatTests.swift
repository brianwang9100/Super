import Testing
@testable import Chat

@Test
func chatPackageIsReachable() {
    #expect(Chat.version == "0.0.1")
}

@Test
func chatLinksCore() {
    #expect(Chat.coreVersion == "0.0.1")
}
