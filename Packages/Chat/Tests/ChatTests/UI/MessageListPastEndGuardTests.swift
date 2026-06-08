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
