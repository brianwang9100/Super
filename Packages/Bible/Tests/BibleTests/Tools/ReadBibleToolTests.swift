import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `ReadBibleTool` — the strict `bible.read` lookup: verse-range
/// resolution, translation validation and current-translation fallback, book/
/// chapter/verse bounds, and the numbered output contract.
@Suite("ReadBibleTool")
struct ReadBibleToolTests {
    private var johnBook: BibleBook {
        BibleBook(
            id: "JHN",
            name: "John",
            testament: .newTestament,
            chapters: [
                BibleChapter(number: 3, paragraphs: [
                    .prose([
                        BibleVerse(number: 16, text: "For God so loved the world."),
                        BibleVerse(number: 17, text: "For God sent not his Son."),
                        BibleVerse(number: 18, text: "He that believeth on him."),
                    ]),
                ]),
            ]
        )
    }

    private func makeTool(
        currentTranslation: String? = nil,
        positionAvailable: Bool = true
    ) -> ReadBibleTool {
        let repository: (any BibleReadingPositionRepository)? = positionAvailable
            ? StubPositionRepository(record: currentTranslation.map {
                BibleReadingPositionRecord(
                    bookId: "JHN", chapterNumber: 3, translationId: $0,
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            })
            : nil
        return ReadBibleTool(
            textLoader: StubBibleTextLoader(book: johnBook),
            positionRepository: repository
        )
    }

    // MARK: - Happy paths

    @Test("no verse range returns every verse in the chapter, numbered")
    func wholeChapter() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3),
        ])
        #expect(result.isError == false)
        #expect(result.content == """
        John 3 (KJV)

        16. For God so loved the world.
        17. For God sent not his Son.
        18. He that believeth on him.
        """)
    }

    @Test("startVerse alone returns just that single verse")
    func singleVerse() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3), "startVerse": .int(16),
        ])
        #expect(result.isError == false)
        #expect(result.content == "John 3:16 (KJV)\n\n16. For God so loved the world.")
    }

    @Test("startVerse and endVerse return the inclusive range")
    func range() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3),
            "startVerse": .int(16), "endVerse": .int(17),
        ])
        #expect(result.isError == false)
        #expect(result.content == """
        John 3:16-17 (KJV)

        16. For God so loved the world.
        17. For God sent not his Son.
        """)
    }

    @Test("a 3-letter code resolves the same as a full name")
    func bookCode() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("JHN"), "chapter": .int(3), "startVerse": .int(16),
        ])
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    // MARK: - Translation resolution

    @Test("an omitted translation uses the user's currently selected translation")
    func omittedTranslationUsesCurrent() async throws {
        let result = try await makeTool(currentTranslation: "ASV").execute(input: [
            "book": .string("John"), "chapter": .int(3), "startVerse": .int(16),
        ])
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (ASV)"))
    }

    @Test("an omitted translation falls back to the default when no position is stored")
    func omittedTranslationNoStoredPosition() async throws {
        let result = try await makeTool(currentTranslation: nil).execute(input: [
            "book": .string("John"), "chapter": .int(3), "startVerse": .int(16),
        ])
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("an omitted translation falls back to the default when the store is unavailable")
    func omittedTranslationNoStore() async throws {
        let result = try await makeTool(positionAvailable: false).execute(input: [
            "book": .string("John"), "chapter": .int(3), "startVerse": .int(16),
        ])
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("an explicit translation overrides the current selection, case-insensitively")
    func explicitTranslation() async throws {
        let result = try await makeTool(currentTranslation: "ASV").execute(input: [
            "book": .string("John"), "chapter": .int(3), "startVerse": .int(16),
            "translation": .string("web"),
        ])
        #expect(result.content.hasPrefix("John 3:16 (WEB)"))
    }

    @Test("an unknown translation is an error, not a silent fallback")
    func unknownTranslation() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3), "translation": .string("XYZ"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown translation"))
    }

    // MARK: - Verse-range errors

    @Test("endVerse below startVerse is an error")
    func endBeforeStart() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3),
            "startVerse": .int(17), "endVerse": .int(16),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("must be ≥"))
    }

    @Test("endVerse without startVerse is an error")
    func endWithoutStart() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3), "endVerse": .int(17),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("without startVerse"))
    }

    @Test("startVerse past the end of the chapter is an error")
    func startVerseOutOfRange() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3), "startVerse": .int(99),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("not found"))
        #expect(result.content.contains("18 verses"))
    }

    @Test("endVerse past the end clamps to the last verse instead of erroring")
    func endVerseClamps() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(3),
            "startVerse": .int(17), "endVerse": .int(9999),
        ])
        #expect(result.isError == false)
        #expect(result.content == """
        John 3:17-18 (KJV)

        17. For God sent not his Son.
        18. He that believeth on him.
        """)
    }

    // MARK: - Book/chapter errors

    @Test("a missing book is an error")
    func missingBook() async throws {
        let result = try await makeTool().execute(input: ["chapter": .int(3)])
        #expect(result.isError == true)
        #expect(result.content.contains("book is required"))
    }

    @Test("an unknown book is an error")
    func unknownBook() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("Nephi"), "chapter": .int(3),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown or ambiguous book"))
    }

    @Test("an ambiguous book prefix is an error")
    func ambiguousBook() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("Jo"), "chapter": .int(1),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown or ambiguous book"))
    }

    @Test("a missing chapter is an error")
    func missingChapter() async throws {
        let result = try await makeTool().execute(input: ["book": .string("John")])
        #expect(result.isError == true)
        #expect(result.content.contains("chapter is required"))
    }

    @Test("a chapter beyond the book is an error")
    func chapterOutOfRange() async throws {
        let result = try await makeTool().execute(input: [
            "book": .string("John"), "chapter": .int(99),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("out of range"))
    }
}

// MARK: - Test doubles

/// A `BibleTextLoader` returning one fixed book, throwing for any other id.
private struct StubBibleTextLoader: BibleTextLoader {
    let book: BibleBook
    func loadBook(id bookID: String, translation: BibleTranslation) throws -> BibleBook {
        guard bookID == book.id else { throw BibleTextLoaderError.bookNotFound(bookID) }
        return book
    }
}

/// An in-memory `BibleReadingPositionRepository` returning a fixed record.
private struct StubPositionRepository: BibleReadingPositionRepository {
    let record: BibleReadingPositionRecord?
    func load() async throws -> BibleReadingPositionRecord? { record }
    func save(_ record: BibleReadingPositionRecord) async throws {}
}
