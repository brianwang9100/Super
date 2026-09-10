import Foundation
import Testing
@testable import Bible

@Suite("BibleNavigationHistory")
struct BibleNavigationHistoryTests {
    private let a = BiblePosition(bookId: "1PE", chapterNumber: 2)
    private let b = BiblePosition(bookId: "JHN", chapterNumber: 3)
    private let c = BiblePosition(bookId: "PSA", chapterNumber: 23)
    private let d = BiblePosition(bookId: "ROM", chapterNumber: 8)

    @Test("initial history contains one current position")
    func initialHistory() {
        let history = BibleNavigationHistory(initialPosition: a)

        #expect(history.entries == [a])
        #expect(history.currentIndex == 0)
        #expect(history.current == a)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test("visiting after back branches and discards forward entries")
    func visitAfterBackBranches() {
        var history = BibleNavigationHistory(initialPosition: a)
        let visitedB = history.visit(b)
        let visitedC = history.visit(c)
        let wentBack = history.goBack()
        #expect(visitedB)
        #expect(visitedC)
        #expect(wentBack)
        #expect(history.current == b)
        #expect(history.canGoForward)

        let visitedD = history.visit(d)
        #expect(visitedD)

        #expect(history.entries == [a, b, d])
        #expect(history.currentIndex == 2)
        #expect(!history.canGoForward)
    }

    @Test("history keeps only the newest 25 visits")
    func capacityTrimsFromFront() {
        var history = BibleNavigationHistory(
            initialPosition: BiblePosition(bookId: "PSA", chapterNumber: 1)
        )
        for chapter in 2...26 {
            let changed = history.visit(
                BiblePosition(bookId: "PSA", chapterNumber: chapter)
            )
            #expect(changed)
        }

        #expect(history.entries.count == 25)
        #expect(history.entries.first == BiblePosition(bookId: "PSA", chapterNumber: 2))
        #expect(history.entries.last == BiblePosition(bookId: "PSA", chapterNumber: 26))
        #expect(history.currentIndex == 24)
    }

    @Test("back and forward stop at their bounds")
    func traversalBounds() {
        var history = BibleNavigationHistory(initialPosition: a)
        let backAtStart = history.goBack()
        let visited = history.visit(b)
        let backToStart = history.goBack()
        let backPastStart = history.goBack()
        let forwardToEnd = history.goForward()
        let forwardPastEnd = history.goForward()
        #expect(!backAtStart)
        #expect(visited)
        #expect(backToStart)
        #expect(!backPastStart)
        #expect(forwardToEnd)
        #expect(!forwardPastEnd)
        #expect(history.current == b)
    }

    @Test("a revisited earlier position remains a distinct entry")
    func retainedRevisit() {
        var history = BibleNavigationHistory(initialPosition: a)
        let visitedB = history.visit(b)
        let revisitedA = history.visit(a)
        #expect(visitedB)
        #expect(revisitedA)

        #expect(history.entries == [a, b, a])
    }

    @Test("visiting the current position after back preserves the forward branch")
    func currentVisitPreservesForwardBranch() {
        var history = BibleNavigationHistory(initialPosition: a)
        let visitedB = history.visit(b)
        let visitedC = history.visit(c)
        let wentBack = history.goBack()
        #expect(visitedB)
        #expect(visitedC)
        #expect(wentBack)

        let changed = history.visit(b)
        #expect(!changed)

        #expect(history.entries == [a, b, c])
        #expect(history.currentIndex == 1)
        #expect(history.canGoForward)
    }

    @Test("visiting the forward destination records it as the new branch tip")
    func forwardDestinationBecomesFreshVisit() {
        var history = BibleNavigationHistory(initialPosition: a)
        let visitedB = history.visit(b)
        let firstVisitC = history.visit(c)
        let wentBack = history.goBack()
        #expect(visitedB)
        #expect(firstVisitC)
        #expect(wentBack)

        let revisitedC = history.visit(c)
        #expect(revisitedC)

        #expect(history.entries == [a, b, c])
        #expect(history.currentIndex == 2)
        #expect(!history.canGoForward)
    }

    @Test("Codable round-trips history and cursor")
    func codableRoundTrip() throws {
        var history = BibleNavigationHistory(initialPosition: a)
        let visitedB = history.visit(b)
        let visitedC = history.visit(c)
        let wentBack = history.goBack()
        #expect(visitedB)
        #expect(visitedC)
        #expect(wentBack)

        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(BibleNavigationHistory.self, from: data)

        #expect(decoded == history)
        #expect(decoded.current == b)
        #expect(decoded.canGoBack)
        #expect(decoded.canGoForward)
    }

    @Test(
        "decoding rejects broken history invariants",
        arguments: [
            #"{"entries":[],"currentIndex":0}"#,
            #"{"entries":[{"bookId":"1PE","chapterNumber":2}],"currentIndex":-1}"#,
            #"{"entries":[{"bookId":"1PE","chapterNumber":2}],"currentIndex":1}"#,
            Self.oversizeHistoryJSON,
        ]
    )
    func rejectsInvalidDecodedHistory(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                BibleNavigationHistory.self,
                from: Data(json.utf8)
            )
        }
    }

    private static let oversizeHistoryJSON: String = {
        let entries = (1...26).map {
            #"{"bookId":"PSA","chapterNumber":\#($0)}"#
        }.joined(separator: ",")
        return #"{"entries":[\#(entries)],"currentIndex":25}"#
    }()
}
