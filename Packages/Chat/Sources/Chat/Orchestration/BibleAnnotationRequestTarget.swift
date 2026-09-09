import Core
import Foundation

/// Validated foreground target; model output never chooses the save destination.
struct BibleAnnotationRequestTarget: Sendable {
    private let fields: [String: JSONValue]

    init(reference: RecordReference) throws {
        let parts = reference.sourceID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard reference.appletID == "bible", parts.count >= 2,
              !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BibleAnnotationStreamError.invalidTarget
        }
        var fields: [String: JSONValue] = ["bookId": .string(parts[1])]
        switch (reference.kind, parts[0], parts.count) {
        case ("book", "book", 2):
            fields["target"] = .string("book")
        case ("chapter", "chapter", 3):
            fields["target"] = .string("chapter")
            fields["chapterNumber"] = .int(try Self.position(parts[2]))
        case ("verseRange", "verse", 5):
            fields["target"] = .string("verse")
            fields["chapterNumber"] = .int(try Self.position(parts[2]))
            let start = try Self.position(parts[3])
            let end = try Self.position(parts[4])
            guard start <= end else { throw BibleAnnotationStreamError.invalidTarget }
            fields["verseStart"] = .int(start)
            fields["verseEnd"] = .int(end)
        default:
            throw BibleAnnotationStreamError.invalidTarget
        }
        self.fields = fields
    }

    func parameters(summary: String) -> [String: JSONValue] {
        fields.merging(["summary": .string(summary)]) { _, value in value }
    }

    private static func position(_ text: String) throws -> Int {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), value > 0 else { throw BibleAnnotationStreamError.invalidTarget }
        return value
    }
}
