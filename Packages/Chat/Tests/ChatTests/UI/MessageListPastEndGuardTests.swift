import Testing
import CoreGraphics
@testable import Chat

/// Tests for `strandedPastEndOffset` — the pure arithmetic behind
/// `MessageList`'s past-end scroll guard.
///
/// The regression these pin: with the keyboard up, `LazyVStack` reports the
/// transcript's `contentHeight` unstably (it flip-flops between two values on
/// alternating layout passes, observed swinging up to ~1100pt during the
/// keyboard glide). A bottom-pin computed against the *larger* alternate leaves
/// `contentOffset` stranded below the content's end when it collapses to the
/// *smaller* alternate, so the small keyboard-up viewport renders blank past
/// the content — the "content momentarily disappears" flicker. The guard
/// detects `offset > contentHeight - containerHeight` and re-pins to the
/// bottom; these cases lock that boundary arithmetic (numbers taken from the
/// on-device trace).
@Suite("MessageList past-end guard")
struct MessageListPastEndGuardTests {
    @Test("Stranded offset past the content end returns the clamped bottom")
    func strandedReturnsBottom() {
        // Trace void tick: content=1792 off=2108 cont=354 → maxOffset = 1438.
        #expect(strandedPastEndOffset(content: 1792, container: 354, offset: 2108) == 1438)
    }

    @Test("Offset within range returns nil (no correction)")
    func inRangeReturnsNil() {
        // Trace tick while scrolled up: content=4303 cont=480 off=2554 is well
        // above the content's end — not stranded.
        #expect(strandedPastEndOffset(content: 4303, container: 480, offset: 2554) == nil)
    }

    @Test("A sub-epsilon overshoot is ignored as benign jitter")
    func subEpsilonIgnored() {
        // maxOffset = 400; offset 402 is 2pt past, within the 4pt epsilon.
        #expect(strandedPastEndOffset(content: 1000, container: 600, offset: 402) == nil)
    }

    @Test("An overshoot beyond epsilon trips the guard")
    func aboveEpsilonTrips() {
        // maxOffset = 400; offset 405 is 5pt past, beyond the 4pt epsilon.
        #expect(strandedPastEndOffset(content: 1000, container: 600, offset: 405) == 400)
    }

    @Test("Content shorter than the container clamps to zero, never negative")
    func shortContentClampsToZero() {
        // content < container → maxOffset floored at 0; any positive offset is
        // past the end and corrects to 0 (never a negative scroll target).
        #expect(strandedPastEndOffset(content: 300, container: 600, offset: 50) == 0)
    }

    @Test("Oscillation: the small-alternate tick after a large-pin is corrected")
    func collapseAfterLargePinCorrected() {
        // Pinned at the large alternate's bottom (~content 3238), then content
        // collapses to 1792 while the offset lingers at the old bottom.
        #expect(strandedPastEndOffset(content: 1792, container: 354, offset: 2884) == 1438)
    }

    @Test("Overscroll-magnitude overshoot trips the function — the caller gates it")
    func overscrollMagnitudeTrips() {
        // A bottom rubber-band bounce overshoots `maxOffset` by tens-to-hundreds
        // of points — far beyond `epsilon`, so this *pure* function reports a
        // correction (maxOffset = 400; an 80pt bounce past it returns 400). The
        // function alone cannot tell a bounce from a strand; the call site is
        // what distinguishes them, by firing only on a container/content-height
        // change (a bounce holds both constant). This test pins that the guard
        // against fighting overscroll lives in the *caller*, not in `epsilon`.
        #expect(strandedPastEndOffset(content: 1000, container: 600, offset: 480) == 400)
    }
}

/// Tests for `shouldSnapOnItemsChange` — the pure snap policy behind
/// `.onChange(of: items.count)`.
///
/// The behavior these pin: the user's own action (the new last row is their
/// bubble — send, regenerate accept) always brings them to the bottom, even
/// from deep in history; assistant-row appends (mid-turn tool-round saves,
/// the final save of a turn) follow only when the user was already at the
/// bottom. A reader scrolled up into history is never yanked by a turn they
/// scrolled away from — and the long-travel animated snap that yank issued
/// was the precondition of the post-stream offset fight.
@Suite("MessageList items-change snap policy")
struct MessageListSnapPolicyTests {
    private let userBubble = MessageList.Item.userBubble(id: "u1", text: "hi", references: [])
    private let assistantRow = MessageList.Item.assistantText(
        id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer",
        toolCalls: [], sources: [], searchSuggestionsHTML: nil,
        searchSystem: nil, searchQuery: nil
    )
    private let banner = MessageList.Item.compactionBanner(id: "b1", summary: "s")

    @Test("User bubble appended: snap regardless of position")
    func userBubbleAlwaysSnaps() {
        #expect(shouldSnapOnItemsChange(lastItem: userBubble, wasAtBottom: false))
        #expect(shouldSnapOnItemsChange(lastItem: userBubble, wasAtBottom: true))
    }

    @Test("Assistant row appended while at the bottom: follow")
    func assistantAtBottomFollows() {
        #expect(shouldSnapOnItemsChange(lastItem: assistantRow, wasAtBottom: true))
    }

    @Test("Assistant row appended while reading history: never yank")
    func assistantScrolledUpStays() {
        #expect(!shouldSnapOnItemsChange(lastItem: assistantRow, wasAtBottom: false))
    }

    @Test("Compaction banner appended: gated like assistant rows")
    func bannerGatedOnBottom() {
        #expect(shouldSnapOnItemsChange(lastItem: banner, wasAtBottom: true))
        #expect(!shouldSnapOnItemsChange(lastItem: banner, wasAtBottom: false))
    }

    @Test("Empty transcript (clear-all): gated on the latch")
    func emptyGatedOnBottom() {
        #expect(!shouldSnapOnItemsChange(lastItem: nil, wasAtBottom: false))
        #expect(shouldSnapOnItemsChange(lastItem: nil, wasAtBottom: true))
    }
}

/// Tests for `shouldReSnapPendingBottom` — the pure decision behind the
/// stream-end settle's per-tick re-snap.
///
/// The regression these pin: after dragging the chat handle to a tiny viewport
/// (keyboard up) and sending, the `LazyVStack` content height thrashes between
/// two values every layout pass while the offset stays correctly pinned to the
/// bottom (`isAtBottom == true`). Re-issuing `scrollTo(.bottom)` on each of
/// those ticks is an offset no-op that re-materializes the lazy rows and
/// sustains the oscillation that blanks the transcript. The fix only re-snaps
/// when content moved *and* the viewport isn't already at the bottom — i.e. a
/// genuine stream-end grow that pushed the bottom out of view.
@Suite("MessageList pending-bottom re-snap gate")
struct MessageListPendingBottomReSnapTests {
    @Test("Content grew and we're no longer at the bottom: re-snap")
    func growAwayFromBottomReSnaps() {
        #expect(shouldReSnapPendingBottom(contentHeightChanged: true, alreadyAtBottom: false))
    }

    @Test("Content changed but already pinned to the bottom: skip (the oscillation tick)")
    func changeWhileAtBottomSkips() {
        // The tiny-viewport flip-flop: contentHeight moved but the offset is
        // already at the bottom — snapping would be a no-op that re-triggers
        // the lazy relayout.
        #expect(!shouldReSnapPendingBottom(contentHeightChanged: true, alreadyAtBottom: true))
    }

    @Test("No content change: never re-snap regardless of position")
    func noChangeNeverReSnaps() {
        #expect(!shouldReSnapPendingBottom(contentHeightChanged: false, alreadyAtBottom: false))
        #expect(!shouldReSnapPendingBottom(contentHeightChanged: false, alreadyAtBottom: true))
    }
}

/// Tests for `pendingBottomSnapBudgetExhausted` — the backstop disarm boundary
/// for the stream-end settle.
///
/// The normal settle disarms via a consecutive-content-stable counter, but in
/// the tiny-viewport oscillation the content height never holds steady, so that
/// counter never advances and the snap would stay armed forever. The tick
/// budget guarantees the settle terminates regardless.
@Suite("MessageList pending-bottom tick budget")
struct MessageListPendingBottomBudgetTests {
    @Test("Below the budget stays armed")
    func belowBudgetStaysArmed() {
        #expect(!pendingBottomSnapBudgetExhausted(totalTicks: 0, maxTicks: 12))
        #expect(!pendingBottomSnapBudgetExhausted(totalTicks: 11, maxTicks: 12))
    }

    @Test("Reaching the budget disarms")
    func reachingBudgetDisarms() {
        #expect(pendingBottomSnapBudgetExhausted(totalTicks: 12, maxTicks: 12))
    }

    @Test("Past the budget disarms")
    func pastBudgetDisarms() {
        #expect(pendingBottomSnapBudgetExhausted(totalTicks: 30, maxTicks: 12))
    }
}

/// Tests for `shouldLandOnBudgetDisarm` — the one-shot safety-net snap when the
/// stream-end settle's tick budget fires while the offset is stranded *above*
/// the last row.
///
/// The case this guards: the budget can disarm `pendingBottomSnap` mid-grow,
/// before the offset has reached the bottom. The stable-disarm path can't strand
/// the user (it only fires once settled at the bottom), and the past-end guard
/// only catches strands *past* the end — so a budget disarm with content still
/// growing below the viewport (`isAtBottom == false`) needs one explicit final
/// snap. Already-at-bottom (the tiny-viewport oscillation) must get none.
@Suite("MessageList budget-disarm safety net")
struct MessageListBudgetDisarmTests {
    @Test("Budget fired, not settled, stranded above bottom: land it")
    func budgetStrandedLands() {
        #expect(shouldLandOnBudgetDisarm(budgetExhausted: true, settled: false, alreadyAtBottom: false))
    }

    @Test("Budget fired but already at bottom (oscillation tick): no extra snap")
    func budgetAtBottomNoSnap() {
        #expect(!shouldLandOnBudgetDisarm(budgetExhausted: true, settled: false, alreadyAtBottom: true))
    }

    @Test("Stable-path disarm (settled) never triggers the safety net")
    func settledDisarmNoSnap() {
        // When `settled` the offset is already at the bottom by definition, so the
        // net must stay out of the way regardless of the other flags.
        #expect(!shouldLandOnBudgetDisarm(budgetExhausted: false, settled: true, alreadyAtBottom: true))
        #expect(!shouldLandOnBudgetDisarm(budgetExhausted: true, settled: true, alreadyAtBottom: false))
    }

    @Test("No disarm at all: no snap")
    func noDisarmNoSnap() {
        #expect(!shouldLandOnBudgetDisarm(budgetExhausted: false, settled: false, alreadyAtBottom: false))
    }
}
