import Testing
@testable import Chat

/// Protects the explicit jump's lifetime from later streaming and user navigation.
struct MessageListBottomScrollRequestTests {
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

    @Test("changed content cancels before completion or correction", arguments: [0.0, 300])
    func changedContentCancels(distance: Double) {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap")
        expectRefinement(false, request: &request, distance: 0)
        expectRefinement(false, request: &request, distance: distance, isRendered: true, content: "new tokens")
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
