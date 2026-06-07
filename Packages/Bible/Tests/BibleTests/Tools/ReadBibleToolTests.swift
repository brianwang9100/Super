import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `ReadBibleTool` — the `bible.read` multi-passage lookup: per-reference
/// verse-range resolution, top-level translation validation and current-translation
/// fallback, book/chapter/verse bounds, partial-success across a `references`
/// array, and the numbered output contract.
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

    private var romansBook: BibleBook {
        BibleBook(
            id: "ROM",
            name: "Romans",
            testament: .newTestament,
            chapters: [
                BibleChapter(number: 8, paragraphs: [
                    .prose([
                        BibleVerse(number: 28, text: "And we know that all things work together for good."),
                    ]),
                ]),
            ]
        )
    }

    /// Acts 8 with verse 37 omitted — a real textual variant some translations
    /// (the bundled WEB) leave out, so `37` is a valid verse number that selects
    /// no text.
    private var actsBookWithGap: BibleBook {
        BibleBook(
            id: "ACT",
            name: "Acts",
            testament: .newTestament,
            chapters: [
                BibleChapter(number: 8, paragraphs: [
                    .prose([
                        BibleVerse(number: 36, text: "And as they went on their way, they came unto a certain water."),
                        BibleVerse(number: 38, text: "And he commanded the chariot to stand still."),
                    ]),
                ]),
            ]
        )
    }

    private func makeTool(
        books: [BibleBook]? = nil,
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
            textLoader: StubBibleTextLoader(books: books ?? [johnBook]),
            positionRepository: repository
        )
    }

    /// A single reference object, with optional verse bounds.
    private func ref(_ book: String, _ chapter: Int, _ start: Int? = nil, _ end: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["book": .string(book), "chapter": .int(chapter)]
        if let start { fields["startVerse"] = .int(start) }
        if let end { fields["endVerse"] = .int(end) }
        return .object(fields)
    }

    /// A tool input wrapping one or more references, with optional top-level translation.
    private func input(_ references: JSONValue..., translation: String? = nil) -> [String: JSONValue] {
        var input: [String: JSONValue] = ["references": .array(references)]
        if let translation { input["translation"] = .string(translation) }
        return input
    }

    // MARK: - Single-reference parity (byte-identical to the old single-passage output)

    @Test("a single reference with no verse range returns every verse in the chapter, numbered")
    func wholeChapter() async throws {
        let result = try await makeTool().execute(input: input(ref("John", 3)))
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
        let result = try await makeTool().execute(input: input(ref("John", 3, 16)))
        #expect(result.isError == false)
        #expect(result.content == "John 3:16 (KJV)\n\n16. For God so loved the world.")
    }

    @Test("startVerse and endVerse return the inclusive range")
    func range() async throws {
        let result = try await makeTool().execute(input: input(ref("John", 3, 16, 17)))
        #expect(result.isError == false)
        #expect(result.content == """
        John 3:16-17 (KJV)

        16. For God so loved the world.
        17. For God sent not his Son.
        """)
    }

    @Test("a 3-letter code resolves the same as a full name")
    func bookCode() async throws {
        let result = try await makeTool().execute(input: input(ref("JHN", 3, 16)))
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("endVerse past the end clamps to the last verse instead of erroring")
    func endVerseClamps() async throws {
        let result = try await makeTool().execute(input: input(ref("John", 3, 17, 9999)))
        #expect(result.isError == false)
        #expect(result.content == """
        John 3:17-18 (KJV)

        17. For God sent not his Son.
        18. He that believeth on him.
        """)
    }

    // MARK: - Multiple references

    @Test("multiple references across different books return all passages in request order")
    func crossBookMulti() async throws {
        let result = try await makeTool(books: [johnBook, romansBook]).execute(
            input: input(ref("John", 3, 16), ref("Romans", 8, 28))
        )
        #expect(result.isError == false)
        #expect(result.content == """
        John 3:16 (KJV)

        16. For God so loved the world.

        Romans 8:28 (KJV)

        28. And we know that all things work together for good.
        """)
    }

    @Test("passages are returned in request order, not canonical Bible order")
    func requestOrderPreserved() async throws {
        let result = try await makeTool(books: [johnBook, romansBook]).execute(
            input: input(ref("Romans", 8, 28), ref("John", 3, 16))
        )
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("Romans 8:28 (KJV)"))
    }

    // MARK: - Partial success

    @Test("a mix of valid and invalid references returns the good passages plus a note, not an error")
    func partialSuccess() async throws {
        let result = try await makeTool(books: [johnBook]).execute(
            input: input(ref("John", 3, 16), ref("Genesis", 99, 1))
        )
        // The whole call is not an error — the model gets the verse it could read.
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
        #expect(result.content.contains("16. For God so loved the world."))
        // …and a correctable note for the reference that failed.
        #expect(result.content.contains("Genesis"))
        #expect(result.content.contains("out of range"))
    }

    @Test("a good passage alongside several failures lists each failure under a count header")
    func partialSuccessWithMultipleFailures() async throws {
        let result = try await makeTool(books: [johnBook]).execute(
            input: input(ref("John", 3, 16), ref("Genesis", 99, 1), ref("Nephi", 1, 1))
        )
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
        // A count header introduces the bulleted, per-reference remediation notes.
        #expect(result.content.contains("2 of 3 references couldn't be read:"))
        #expect(result.content.contains("• Chapter 99 is out of range"))
        #expect(result.content.contains("• Unknown or ambiguous book 'Nephi'"))
    }

    @Test("when every reference fails the whole call is an error carrying each message")
    func allReferencesFail() async throws {
        let result = try await makeTool().execute(
            input: input(ref("Genesis", 99, 1), ref("Nephi", 1, 1))
        )
        #expect(result.isError == true)
        #expect(result.content.contains("out of range"))
        #expect(result.content.contains("Unknown or ambiguous book"))
    }

    // MARK: - Array shape errors

    @Test("an empty references array is an error")
    func emptyReferences() async throws {
        let result = try await makeTool().execute(input: ["references": .array([])])
        #expect(result.isError == true)
        #expect(result.content.contains("references is required"))
    }

    @Test("a missing references array is an error")
    func missingReferences() async throws {
        let result = try await makeTool().execute(input: [:])
        #expect(result.isError == true)
        #expect(result.content.contains("references is required"))
    }

    @Test("more than 25 references is an error telling the model to split the call")
    func tooManyReferences() async throws {
        let many = (1...(ReadBibleTool.maxReferences + 1)).map { _ in JSONValue.object(["book": .string("John"), "chapter": .int(3)]) }
        let result = try await makeTool().execute(input: ["references": .array(many)])
        #expect(result.isError == true)
        #expect(result.content.contains("25"))
    }

    // MARK: - Translation resolution (top-level, applies to every reference)

    @Test("an omitted translation uses the user's currently selected translation")
    func omittedTranslationUsesCurrent() async throws {
        let result = try await makeTool(currentTranslation: "ASV").execute(input: input(ref("John", 3, 16)))
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (ASV)"))
    }

    @Test("an omitted translation falls back to the default when no position is stored")
    func omittedTranslationNoStoredPosition() async throws {
        let result = try await makeTool(currentTranslation: nil).execute(input: input(ref("John", 3, 16)))
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("an omitted translation falls back to the default when the store is unavailable")
    func omittedTranslationNoStore() async throws {
        let result = try await makeTool(positionAvailable: false).execute(input: input(ref("John", 3, 16)))
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("an explicit top-level translation applies to every reference, case-insensitively")
    func explicitTranslationAppliesToAll() async throws {
        let result = try await makeTool(books: [johnBook, romansBook], currentTranslation: "ASV").execute(
            input: input(ref("John", 3, 16), ref("Romans", 8, 28), translation: "web")
        )
        #expect(result.isError == false)
        #expect(result.content.contains("John 3:16 (WEB)"))
        #expect(result.content.contains("Romans 8:28 (WEB)"))
    }

    @Test("an unknown translation is an error for the whole call, not a silent fallback")
    func unknownTranslation() async throws {
        let result = try await makeTool().execute(
            input: input(ref("John", 3), translation: "XYZ")
        )
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown translation"))
    }

    // MARK: - Per-reference verse-range errors

    @Test("endVerse below startVerse is an error")
    func endBeforeStart() async throws {
        let result = try await makeTool().execute(input: input(ref("John", 3, 17, 16)))
        #expect(result.isError == true)
        #expect(result.content.contains("must be ≥"))
    }

    @Test("endVerse without startVerse is an error")
    func endWithoutStart() async throws {
        let result = try await makeTool().execute(input: input(.object([
            "book": .string("John"), "chapter": .int(3), "endVerse": .int(17),
        ])))
        #expect(result.isError == true)
        #expect(result.content.contains("without startVerse"))
    }

    @Test("startVerse past the end of the chapter is an error")
    func startVerseOutOfRange() async throws {
        let result = try await makeTool().execute(input: input(ref("John", 3, 99)))
        #expect(result.isError == true)
        #expect(result.content.contains("not found"))
        #expect(result.content.contains("18 verses"))
    }

    // MARK: - Per-reference book/chapter errors

    @Test("a reference missing its book is an error")
    func missingBook() async throws {
        let result = try await makeTool().execute(input: input(.object(["chapter": .int(3)])))
        #expect(result.isError == true)
        #expect(result.content.contains("book is required"))
    }

    @Test("an unknown book is an error")
    func unknownBook() async throws {
        let result = try await makeTool().execute(input: input(ref("Nephi", 3)))
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown or ambiguous book"))
    }

    @Test("an ambiguous book prefix is an error")
    func ambiguousBook() async throws {
        let result = try await makeTool().execute(input: input(ref("Jo", 1)))
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown or ambiguous book"))
    }

    @Test("a reference missing its chapter is an error")
    func missingChapter() async throws {
        let result = try await makeTool().execute(input: input(.object(["book": .string("John")])))
        #expect(result.isError == true)
        #expect(result.content.contains("chapter is required"))
    }

    @Test("a chapter beyond the book is an error")
    func chapterOutOfRange() async throws {
        let result = try await makeTool().execute(input: input(ref("John", 99)))
        #expect(result.isError == true)
        #expect(result.content.contains("out of range"))
    }

    // MARK: - Omitted verses (textual variants)

    @Test("a verse the translation omits is an error, not an empty body")
    func omittedSingleVerseErrors() async throws {
        let result = try await makeTool(books: [actsBookWithGap]).execute(input: input(ref("Acts", 8, 37)))
        #expect(result.isError == true)
        #expect(result.content.contains("no verse text"))
    }

    @Test("a range spanning an omitted verse returns the present verses")
    func rangeAcrossOmittedVerse() async throws {
        let result = try await makeTool(books: [actsBookWithGap]).execute(input: input(ref("Acts", 8, 36, 38)))
        #expect(result.isError == false)
        // The citation reflects which verses are actually present (36 and 38),
        // and the omitted verse 37 is absent from the body.
        #expect(result.content.hasPrefix("Acts 8:36, 38 (KJV)"))
        #expect(result.content.contains("36. "))
        #expect(result.content.contains("38. "))
        #expect(!result.content.contains("37."))
    }

    @Test("a whole-chapter read of a chapter with a verse gap still succeeds")
    func wholeChapterWithGapSucceeds() async throws {
        let result = try await makeTool(books: [actsBookWithGap]).execute(input: input(ref("Acts", 8)))
        #expect(result.isError == false)
        #expect(result.content.contains("36. "))
        #expect(result.content.contains("38. "))
    }
}

// MARK: - Test doubles

/// A `BibleTextLoader` serving chapters from a fixed set of books; `nil` for any
/// other book id or an absent chapter (mirroring the DB loader's missing-row case).
private struct StubBibleTextLoader: BibleTextLoader {
    let books: [BibleBook]
    func loadChapter(
        bookId: String, chapterNumber: Int, translation: BibleTranslation
    ) throws -> BibleChapter? {
        guard let book = books.first(where: { $0.id == bookId }) else { return nil }
        return book.chapter(chapterNumber)
    }
}
