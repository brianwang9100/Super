import Foundation
import Testing
@testable import Chat

/// Protects the explicit jump's lifetime from later streaming and user navigation.
struct MessageListBottomScrollRequestTests {
    @Test("tokens and persistence keep a jump alive until rendered arrival")
    @MainActor
    func activeResponseReachesRenderedBottom() {
        let user = MessageList.Item.userBubble(id: "turn", text: "Question", references: [])
        let saved = MessageList.Item.assistantText(
            id: "answer", thinking: nil, thinkingDurationMs: nil, text: "Saved response",
            toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
        )
        func content(_ items: [MessageList.Item]) -> MessageList.BottomScrollContext {
            MessageList.BottomScrollContext(
                turnID: MessageListTurn.group(items).last?.id, viewport: CGSize(width: 402, height: 600),
                verbosity: .simple, thinkingExpansion: [:]
            )
        }
        let initial = content([user])
        var request = MessageListBottomScrollRequest<MessageList.BottomScrollContext>()
        request.begin(content: initial)
        let provisional = request.shouldRefine(distanceToBottom: 0, isRendered: false, content: initial)
        #expect(!provisional)
        // Streaming text is not part of the turn/layout request identity.
        let tokenCorrection = request.shouldRefine(
            distanceToBottom: 200, isRendered: false, content: content([user])
        )
        #expect(tokenCorrection)
        let persisted = content([user, saved])
        let renderedCorrection = request.shouldRefine(distanceToBottom: 120, isRendered: true, content: persisted)
        #expect(renderedCorrection)
        let arrival = request.shouldRefine(distanceToBottom: 0, isRendered: true, content: persisted)
        #expect(!arrival)
        let laterGrowth = request.shouldRefine(
            distanceToBottom: 300, isRendered: true, content: content([user, saved])
        )
        #expect(!laterGrowth)
    }

    @Test("a provisional bottom does not discard later lazy-layout correction")
    func provisionalBottomKeepsCorrection() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap")
        expectRefinement(false, request: &request, distance: 0)
        expectRefinement(true, request: &request, distance: 300, isRendered: true)
        expectRefinement(false, request: &request, distance: 0, isRendered: true)
        expectRefinement(false, request: &request, distance: 500, isRendered: true)
    }

    @Test("content growth never starts or resumes a completed jump")
    func growthDoesNotFollow() {
        var request = MessageListBottomScrollRequest<String>()
        expectRefinement(false, request: &request, distance: 400)
        request.begin(content: "tap")
        expectRefinement(true, request: &request, distance: 300)
        expectRefinement(false, request: &request, distance: 0, isRendered: true)
        expectRefinement(false, request: &request, distance: 500)
    }

    @Test("lazy estimates have a bounded correction budget")
    func correctionsAreBounded() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap")
        for _ in 0..<4 {
            expectRefinement(true, request: &request, distance: 100)
        }
        expectRefinement(false, request: &request, distance: 100)
        expectRefinement(false, request: &request, distance: 500)
    }

    @Test("manual scrolling and new sends can cancel the jump")
    func navigationCancels() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap")
        expectRefinement(true, request: &request, distance: 100)
        request.cancel()
        expectRefinement(false, request: &request, distance: 200)
        request.begin(content: "tap")
        expectRefinement(true, request: &request, distance: 200)
    }

    @Test("rendered bottom tolerance and overscroll finish the request", arguments: [-20.0, 0, 1, 2])
    func bottomFinishes(distance: Double) {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap")
        expectRefinement(false, request: &request, distance: distance, isRendered: true)
        expectRefinement(false, request: &request, distance: 200)
    }

    @Test("changed turn or layout cancels before completion or correction", arguments: [0.0, 300])
    func changedContextCancels(distance: Double) {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap")
        expectRefinement(false, request: &request, distance: 0)
        expectRefinement(false, request: &request, distance: distance, isRendered: true, content: "another turn or layout")
        expectRefinement(false, request: &request, distance: 300, isRendered: true)
    }

    private func expectRefinement(
        _ expected: Bool, request: inout MessageListBottomScrollRequest<String>, distance: Double, isRendered: Bool = false, content: String = "tap",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = request.shouldRefine(distanceToBottom: distance, isRendered: isRendered, content: content)
        #expect(actual == expected, sourceLocation: sourceLocation)
    }
}
