import Foundation
import Testing
@testable import Bible

/// Tests for `BibleToolTranslationResolver` — the translation-argument resolution
/// shared by the read and search paths of `bible.lookup`: explicit strict validation, the
/// current-translation fallback, and the default when no position is available.
@Suite("BibleToolTranslationResolver")
struct BibleToolTranslationResolverTests {
    private func repository(_ code: String?) -> any BibleReadingPositionRepository {
        StubPositionRepository(record: code.map {
            BibleReadingPositionRecord(
                bookId: "JHN", chapterNumber: 3, translationId: $0,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        })
    }

    @Test("an explicit code resolves, case-insensitively")
    func explicitCode() async throws {
        let translation = try await BibleToolTranslationResolver.resolve(
            explicitCode: "web", positionRepository: repository("ASV")
        )
        #expect(translation == .web)
    }

    @Test("an unknown explicit code throws, listing the valid codes")
    func unknownCode() async throws {
        await #expect(throws: BibleToolValidationError.self) {
            try await BibleToolTranslationResolver.resolve(
                explicitCode: "XYZ", positionRepository: repository(nil)
            )
        }
    }

    @Test("a nil code uses the stored current translation")
    func nilCodeUsesCurrent() async throws {
        let translation = try await BibleToolTranslationResolver.resolve(
            explicitCode: nil, positionRepository: repository("ASV")
        )
        #expect(translation == .asv)
    }

    @Test("a blank code is treated as omitted")
    func blankCodeUsesCurrent() async throws {
        let translation = try await BibleToolTranslationResolver.resolve(
            explicitCode: "   ", positionRepository: repository("ASV")
        )
        #expect(translation == .asv)
    }

    @Test("a nil code with no stored position falls back to the default")
    func nilCodeNoPosition() async throws {
        let translation = try await BibleToolTranslationResolver.resolve(
            explicitCode: nil, positionRepository: repository(nil)
        )
        #expect(translation == .defaultTranslation)
    }

    @Test("a nil code with an unavailable store falls back to the default")
    func nilCodeNoStore() async throws {
        let translation = try await BibleToolTranslationResolver.resolve(
            explicitCode: nil, positionRepository: nil
        )
        #expect(translation == .defaultTranslation)
    }

    @Test("a stored unknown code falls back to the default")
    func storedUnknownCode() async throws {
        let translation = try await BibleToolTranslationResolver.resolve(
            explicitCode: nil, positionRepository: repository("ZZZ")
        )
        #expect(translation == .defaultTranslation)
    }
}
