import Foundation

public struct BibleTextLocator: Codable, Sendable, Equatable, Hashable {
    public var position: BiblePosition
    public var translationId: String
    public var verseNumber: Int
    /// UTF-16 offset within the verse's source fragments, excluding printed markers.
    public var utf16Offset: Int
    /// Identifies non-scripture content while retaining the verse locator as a removal fallback.
    var supplement: Supplement?

    struct Supplement: Codable, Sendable, Equatable, Hashable {
        var id: String
        var utf16Offset: Int
    }

    public init(position: BiblePosition, translation: BibleTranslation, verseNumber: Int = 1, utf16Offset: Int = 0) {
        self.position = position
        self.translationId = translation.rawValue
        self.verseNumber = verseNumber
        self.utf16Offset = utf16Offset
    }
}

struct BibleBookLocation: Codable, Sendable, Equatable {
    var version = 1
    var current: BibleTextLocator
    var spreadOrigin: BibleTextLocator

    static func decode(_ json: String?) -> Self? {
        guard let data = json?.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
              [value.current, value.spreadOrigin].allSatisfy({
                  $0.verseNumber > 0 && $0.utf16Offset >= 0 && BibleTranslation(rawValue: $0.translationId) != nil
                      && ($0.supplement.map { !$0.id.isEmpty && $0.utf16Offset >= 0 } ?? true)
              }) else { return nil }
        return value
    }

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
