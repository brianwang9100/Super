import Testing
@testable import Chat

/// Focus commands follow explicit intent and native motion, not streamed content.
@Suite("MessageList focus sequencing")
@MainActor
struct MessageListFocusTests {
    private let first = MessageList.ScrollRequest(messageID: "first", sequence: 1)

    @Test("animation frames cannot restart a seek or consume its correction budget")
    func framesWaitForMotionToEnd() {
        let focus = MessageListFocus()
        #expect(focus.begin(first, animated: true) == .init(request: first, animated: true))
        focus.motionBegan()
        for y in stride(from: 600, through: 20, by: -10) {
            #expect(focus.measure(.init(request: first, viewportY: Double(y))) == nil)
        }
        #expect(focus.motionEnded(awaiting: 1))
        #expect(focus.measure(.init(request: first, viewportY: 20, measurementID: 1)) == .init(request: first, animated: true))
        #expect(focus.measure(.init(request: first, viewportY: 8, measurementID: 1)) == nil)
        #expect(focus.motionEnded(awaiting: 2))
        #expect(focus.measure(.init(request: first, viewportY: 8, measurementID: 2)) == nil)
        #expect(focus.measure(.init(request: first, viewportY: 600, measurementID: 2)) == nil)
    }

    @Test("crossing the target during a lazy seek does not prematurely complete focus")
    func overshootUsesFinalGeometry() {
        let focus = MessageListFocus()
        _ = focus.begin(first, animated: true)
        #expect(focus.measure(.init(request: first, viewportY: 0)) == nil)
        #expect(focus.measure(.init(request: first, viewportY: -90)) == nil)
        #expect(focus.motionEnded(awaiting: 1))
        #expect(focus.measure(.init(request: first, viewportY: -90, measurementID: 1)) == .init(request: first, animated: true))
    }

    @Test("a final target measurement delivered after idle still corrects overshoot")
    func finalMeasurementCanFollowIdle() {
        let focus = MessageListFocus()
        _ = focus.begin(first, animated: true)
        _ = focus.measure(.init(request: first, viewportY: 0))
        #expect(focus.motionEnded(awaiting: 1))
        #expect(focus.measure(.init(request: first, viewportY: 0)) == nil)
        #expect(focus.measure(.init(request: first, viewportY: -90, measurementID: 1)) == .init(request: first, animated: true))
    }

    @Test("a user drag cancels both pending corrections and late motion callbacks")
    func dragCancelsFocus() {
        let focus = MessageListFocus()
        _ = focus.begin(first, animated: true)
        _ = focus.measure(.init(request: first, viewportY: 300))
        focus.cancel()
        focus.motionBegan()
        #expect(!focus.motionEnded(awaiting: 3))
        #expect(focus.measure(.init(request: first, viewportY: 500)) == nil)
        #expect(focus.begin(first, animated: true) == nil)

        let retry = MessageList.ScrollRequest(messageID: "first", sequence: 2)
        #expect(focus.begin(retry, animated: true) == .init(request: retry, animated: true))
    }

    @Test("a newer request ignores old geometry and corrects only its own destination")
    func newRequestSupersedesOldMotion() {
        let focus = MessageListFocus()
        _ = focus.begin(first, animated: true)
        _ = focus.measure(.init(request: first, viewportY: 300))
        let second = MessageList.ScrollRequest(messageID: "second", sequence: 2)
        #expect(focus.begin(second, animated: true) == .init(request: second, animated: true))
        _ = focus.measure(.init(request: second, viewportY: 50))
        #expect(focus.measure(.init(request: first, viewportY: 0)) == nil)
        #expect(focus.motionEnded(awaiting: 1))
        #expect(focus.measure(.init(request: second, viewportY: 50, measurementID: 1)) == .init(request: second, animated: true))
        _ = focus.measure(.init(request: second, viewportY: 8, measurementID: 1))
        #expect(focus.motionEnded(awaiting: 2))
        #expect(focus.measure(.init(request: second, viewportY: 8, measurementID: 2)) == nil)
        #expect(focus.measure(.init(request: first, viewportY: 400)) == nil)
        #expect(!focus.motionEnded(awaiting: 3))
    }

    @Test("an already aligned target needs no animation or animation-end event")
    func alreadyAlignedDoesNotWaitForMotion() {
        let focus = MessageListFocus()
        #expect(focus.measure(.init(request: first, viewportY: 8)) == nil)
        #expect(focus.begin(first, animated: true) == nil)
        #expect(focus.measure(.init(request: first, viewportY: 400)) == nil)
    }

    @Test("immediate positioning refines without waiting for animation callbacks")
    func reduceMotionAndMountAreImmediate() {
        let focus = MessageListFocus()
        #expect(focus.begin(first, animated: false) == .init(request: first, animated: false))
        #expect(focus.measure(.init(request: first, viewportY: 290)) == .init(request: first, animated: false))
        #expect(focus.measure(.init(request: first, viewportY: 8)) == nil)
        #expect(focus.measure(.init(request: first, viewportY: 100)) == nil)
    }

    @Test("an unresolvable target cannot cause endless animated corrections")
    func correctionsAreBounded() {
        let focus = MessageListFocus()
        _ = focus.begin(first, animated: true)
        var corrections = 0
        for id in 1...100 {
            if focus.motionEnded(awaiting: id),
               focus.measure(.init(request: first, viewportY: 100, measurementID: id)) != nil {
                corrections += 1
            }
        }
        #expect(corrections > 0 && corrections < 10)
        #expect(focus.measure(.init(request: first, viewportY: 200)) == nil)
    }
}
