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

    @Test("every paragraph kind encodes its discriminator and payload")
    func encodesEveryKind() throws {
        let cases: [(BibleParagraph, String)] = [
            (.heading("A title"), #"{"type":"heading","text":"A title"}"#),
            (.prose([BibleVerse(number: 1, text: "text")]), #"{"type":"prose","verses":[{"number":1,"text":"text"}]}"#),
            (.poetry([BibleVerse(number: 8, text: "line\nbreak")]), #"{"type":"poetry","verses":[{"number":8,"text":"line\nbreak"}]}"#),
        ]
        for (paragraph, json) in cases {
            let encoded = try JSONEncoder().encode(paragraph)
            let expected = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
            #expect(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary == expected)
            #expect(try decoder.decode(BibleParagraph.self, from: encoded) == paragraph)
        }
    }

    @Test("known paragraph kinds reject missing or wrongly typed payloads", arguments: [
        #"{"type":"heading"}"#, #"{"type":"heading","text":42}"#,
        #"{"type":"prose"}"#, #"{"type":"poetry","verses":"wrong"}"#,
    ])
    func rejectsInvalidPayload(_ json: String) {
        #expect(throws: DecodingError.self) {
            try decoder.decode(BibleParagraph.self, from: Data(json.utf8))
        }
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
            try decoder.decode(BibleParagraph.self, from: json)
        }
    }
}
