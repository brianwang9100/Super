import Foundation
import Testing
@testable import Bible

/// Tests for `BibleParagraph`'s discriminated-union Codable: each `type`
/// decodes to the matching case, and unknown or malformed input is rejected.
@Suite("BibleParagraph coding")
struct BibleParagraphTests {
    private let decoder = JSONDecoder()

    @Test("heading decodes from its type tag")
    func decodesHeading() throws {
        let json = Data(#"{"type":"heading","text":"A Living Stone"}"#.utf8)
        #expect(try decoder.decode(BibleParagraph.self, from: json) == .heading("A Living Stone"))
    }

    @Test("prose and poetry decode their verse arrays")
    func decodesVerseParagraphs() throws {
        let prose = Data(#"{"type":"prose","verses":[{"number":1,"text":"a"}]}"#.utf8)
        let poetry = Data(#"{"type":"poetry","verses":[{"number":6,"text":"b"}]}"#.utf8)
        #expect(try decoder.decode(BibleParagraph.self, from: prose)
            == .prose([BibleVerse(number: 1, text: "a")]))
        #expect(try decoder.decode(BibleParagraph.self, from: poetry)
            == .poetry([BibleVerse(number: 6, text: "b")]))
    }

    @Test("round-trips through encode then decode")
    func roundTrips() throws {
        let original: BibleParagraph = .poetry([BibleVerse(number: 8, text: "line\nbreak")])
        let encoded = try JSONEncoder().encode(original)
        #expect(try decoder.decode(BibleParagraph.self, from: encoded) == original)
    }

    @Test("an unknown type tag is rejected")
    func rejectsUnknownType() {
        let json = Data(#"{"type":"footnote","text":"x"}"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(BibleParagraph.self, from: json)
        }
    }

    @Test("malformed JSON is rejected")
    func rejectsMalformedJSON() {
        let json = Data(#"{"type":"prose","verses":"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(BibleBook.self, from: json)
        }
    }
}
