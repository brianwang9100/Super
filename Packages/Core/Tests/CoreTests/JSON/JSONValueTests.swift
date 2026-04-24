import Testing
import Foundation
@testable import Core

/// Tests for `JSONValue` Codable round-trip across scalars, arrays, and
/// nested objects.
@Suite("JSONValue")
struct JSONValueTests {
    private func roundTrip(_ value: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func encodesAndDecodesScalars() throws {
        #expect(try roundTrip(.null) == .null)
        #expect(try roundTrip(.bool(true)) == .bool(true))
        #expect(try roundTrip(.int(42)) == .int(42))
        #expect(try roundTrip(.double(3.14)) == .double(3.14))
        #expect(try roundTrip(.string("hello")) == .string("hello"))
    }

    @Test func encodesAndDecodesArrays() throws {
        let value: JSONValue = .array([.int(1), .string("two"), .bool(false)])
        #expect(try roundTrip(value) == value)
    }

    @Test func encodesAndDecodesNestedObjects() throws {
        let value: JSONValue = .object([
            "name": .string("Brian"),
            "age": .int(35),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .object(["active": .bool(true)]),
        ])
        let decoded = try roundTrip(value)
        #expect(decoded == value)
    }

    @Test func decodesNullExplicitly() throws {
        let data = "null".data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .null)
    }
}
