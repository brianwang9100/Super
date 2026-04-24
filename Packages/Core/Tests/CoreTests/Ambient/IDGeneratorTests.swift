import Testing
@testable import Core

/// Tests for `UUIDGenerator` uniqueness and `DeterministicIDGenerator`
/// counter behavior.
@Suite("IDGenerator")
struct IDGeneratorTests {
    @Test func uuidGeneratorReturnsUniqueValues() {
        let generator = UUIDGenerator()
        let a = generator.nextID()
        let b = generator.nextID()
        #expect(a != b)
        #expect(a.count == 36)
    }

    @Test func deterministicGeneratorIncrementsFromStart() {
        let generator = DeterministicIDGenerator(prefix: "msg-", start: 0)
        #expect(generator.nextID() == "msg-1")
        #expect(generator.nextID() == "msg-2")
        #expect(generator.nextID() == "msg-3")
    }

    @Test func deterministicGeneratorRespectsStartOffset() {
        let generator = DeterministicIDGenerator(prefix: "x-", start: 100)
        #expect(generator.nextID() == "x-101")
    }
}
