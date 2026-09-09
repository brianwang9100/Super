import Foundation
import Testing
@testable import Chat

/// Protects the explicit jump's lifetime from later streaming and user navigation.
struct MessageListBottomScrollRequestTests {
    @Test("native motion starting after completion suppresses fallback geometry")
    func delayedNativeMotionRearmsSuppression() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap", animated: true)
        let fallback = request.animationCompleted(for: request.movementID, awaiting: 1)
        #expect(fallback)
        request.motionBegan()
        let intermediate = request.shouldRefine(
            distanceToBottom: 0, isRendered: true, content: "tap", measurementID: 1
        )
        #expect(!intermediate)
        let ended = request.motionEnded(awaiting: 2)
        #expect(ended)
        let oldSample = request.shouldRefine(
            distanceToBottom: 0, isRendered: true, content: "tap", measurementID: 1
        )
        #expect(!oldSample)
        let correction = request.shouldRefine(
            distanceToBottom: 100, isRendered: true, content: "tap", measurementID: 2
        )
        #expect(correction)
    }

    @Test("a seek with no native motion still corrects newly rendered content")
    func noMotionSeekCanRecover() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap", animated: true)
        let firstMove = request.movementID
        let motionResult1 = request.animationCompleted(for: firstMove, awaiting: 1)
        #expect(motionResult1)
        let estimatedArrival = request.shouldRefine(
            distanceToBottom: 0, isRendered: false, content: "tap", measurementID: 1
        )
        #expect(!estimatedArrival)
        // The other producer can still deliver an old rendered sample.
        expectRefinement(false, request: &request, distance: 0, isRendered: true)
        let correction = request.shouldRefine(
            distanceToBottom: 200, isRendered: true, content: "tap", measurementID: 1
        )
        #expect(correction)
        let motionResult2 = request.animationCompleted(for: firstMove, awaiting: 2)
        #expect(!motionResult2)
        let nextMove = request.movementID
        request.motionBegan()
        // Animation transaction completion cannot end actual native motion.
        let motionResult3 = request.animationCompleted(for: nextMove, awaiting: 2)
        #expect(!motionResult3)
        let motionResult4 = request.motionEnded(awaiting: 2)
        #expect(motionResult4)
        let arrival = request.shouldRefine(
            distanceToBottom: 0, isRendered: true, content: "tap", measurementID: 2
        )
        #expect(!arrival)
        expectRefinement(false, request: &request, distance: 300, isRendered: true)
    }

    @Test("animation frames wait for fresh geometry after native motion ends")
    func animatedFramesWaitForCompletion() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap", animated: true)
        request.motionBegan()
        for distance in stride(from: 600.0, through: -20, by: -10) {
            expectRefinement(false, request: &request, distance: distance, isRendered: true)
        }
        let motionResult5 = request.motionEnded(awaiting: 1)
        #expect(motionResult5)
        // A late final-frame sample must not finish the request before the
        // fresh layout sample reveals the remaining lazy-layout distance.
        expectRefinement(false, request: &request, distance: 0, isRendered: true)
        let correction = request.shouldRefine(
            distanceToBottom: 100, isRendered: true, content: "tap", measurementID: 1
        )
        #expect(correction)
        expectRefinement(false, request: &request, distance: 0, isRendered: true)
        let motionResult6 = request.motionEnded(awaiting: 2)
        #expect(motionResult6)
        let arrival = request.shouldRefine(
            distanceToBottom: 0, isRendered: true, content: "tap", measurementID: 2
        )
        #expect(!arrival)
        expectRefinement(false, request: &request, distance: 500, isRendered: true)
        let motionResult7 = request.motionEnded(awaiting: 3)
        #expect(!motionResult7)
    }

    @Test("each completed animation uses at most one bounded correction")
    func animatedCorrectionsAreBounded() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap", animated: true)
        for measurementID in 1...5 {
            for _ in 0..<10 {
                expectRefinement(false, request: &request, distance: 100)
            }
            let motionResult8 = request.motionEnded(awaiting: measurementID)
            #expect(motionResult8)
            let correction = request.shouldRefine(
                distanceToBottom: 100, isRendered: true, content: "tap", measurementID: measurementID
            )
            #expect(correction == (measurementID <= 4))
        }
        let motionResult9 = request.motionEnded(awaiting: 6)
        #expect(!motionResult9)
    }

    @Test("cancelled motion cannot resume from late callbacks")
    func cancelledMotionStaysCancelled() {
        var request = MessageListBottomScrollRequest<String>()
        request.begin(content: "tap", animated: true)
        request.cancel()
        request.motionBegan()
        let motionResult10 = request.motionEnded(awaiting: 1)
        #expect(!motionResult10)
        expectRefinement(false, request: &request, distance: 200, isRendered: true)
        // Reduce Motion needs neither animation nor an animation-end event.
        request.begin(content: "tap", animated: false)
        expectRefinement(true, request: &request, distance: 200, isRendered: true)
        expectRefinement(false, request: &request, distance: 0, isRendered: true)
        let motionResult11 = request.motionEnded(awaiting: 2)
        #expect(!motionResult11)
    }

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
