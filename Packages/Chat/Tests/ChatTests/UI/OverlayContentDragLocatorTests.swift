import Foundation
import Testing
@testable import Chat

/// Tests for `frontmostInsetScrollIndex` — the pure geometry behind the
/// content-drag locator's fallback (used when the keyboard-up hit-test resolves
/// to non-scrolling chrome).
///
/// The regression these pin: the body-drag pan attaches to the app's root
/// hosting view, which also hosts the backdrop applet's **full-window** scroll
/// view behind the chat overlay. The locator must resolve the **inset chat
/// transcript** under the finger and never the full-window backdrop — and must
/// resolve to nothing in the empty state (only the backdrop under the touch),
/// so the caller drives the resize immediately instead of arming from the
/// backdrop's scroll position.
@Suite("Content-drag scroll-view locator geometry")
struct OverlayContentDragLocatorTests {
    private let windowHeight: CGFloat = 800

    /// Frames in back-to-front order: the full-window backdrop, then the inset
    /// transcript composited in front of it.
    private let backdrop = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let transcript = CGRect(x: 0, y: 400, width: 400, height: 300)

    @Test("Picks the inset transcript, not the full-window backdrop")
    func picksInsetOverBackdrop() {
        let index = frontmostInsetScrollIndex(
            frames: [backdrop, transcript],
            containing: CGPoint(x: 200, y: 500),
            windowHeight: windowHeight
        )
        #expect(index == 1)
    }

    @Test("Among multiple inset candidates the frontmost (last) wins")
    func frontmostInsetWins() {
        let lower = CGRect(x: 0, y: 450, width: 400, height: 300)
        let index = frontmostInsetScrollIndex(
            frames: [backdrop, transcript, lower],
            containing: CGPoint(x: 200, y: 500),
            windowHeight: windowHeight
        )
        // Both `transcript` (idx 1) and `lower` (idx 2) contain the point;
        // `lower` is later in front-to-back order, so it's the frontmost.
        #expect(index == 2)
    }

    @Test("Empty state: only the full-window backdrop under the touch → nil")
    func emptyStateExcludesBackdrop() {
        let index = frontmostInsetScrollIndex(
            frames: [backdrop],
            containing: CGPoint(x: 200, y: 500),
            windowHeight: windowHeight
        )
        #expect(index == nil)
    }

    @Test("A touch outside every inset scroll view resolves to nil")
    func touchOutsideInsetIsNil() {
        let index = frontmostInsetScrollIndex(
            frames: [backdrop, transcript],
            containing: CGPoint(x: 200, y: 100),
            windowHeight: windowHeight
        )
        // (200, 100) is in the backdrop (excluded, full-window) but above the
        // transcript, so nothing inset contains it.
        #expect(index == nil)
    }

    @Test("A tall inset transcript reaching the bottom edge is still selected")
    func tallInsetTranscriptStillSelected() {
        // Inset at the top by the surface chrome (minY > 1) but extending to the
        // window's bottom edge. This is *not* the backdrop — exclusion keys on
        // covering the window top-to-bottom, not on height alone — so a touch
        // inside it still resolves to it.
        let tallTranscript = CGRect(x: 0, y: 60, width: 400, height: 740)
        let index = frontmostInsetScrollIndex(
            frames: [backdrop, tallTranscript],
            containing: CGPoint(x: 200, y: 500),
            windowHeight: windowHeight
        )
        #expect(index == 1)
    }

    @Test("coversWindowVertically flags the backdrop but never the inset transcript")
    func coversWindowVerticallyClassifies() {
        // Backdrop: spans top-to-bottom → full-window.
        #expect(coversWindowVertically(backdrop, windowHeight: windowHeight))
        // Sub-point safe-area rounding on the backdrop is still full-window.
        #expect(coversWindowVertically(
            CGRect(x: 0, y: 0.5, width: 400, height: 799.3), windowHeight: windowHeight
        ))
        // Transcript inset below the chrome, even reaching the bottom edge → not.
        #expect(!coversWindowVertically(
            CGRect(x: 0, y: 116, width: 400, height: 684), windowHeight: windowHeight
        ))
        #expect(!coversWindowVertically(
            CGRect(x: 0, y: 60, width: 400, height: 740), windowHeight: windowHeight
        ))
    }

    @Test("Full-window exclusion uses a 1-point epsilon for backdrop rounding")
    func fullWindowEpsilon() {
        let point = CGPoint(x: 200, y: 400)
        // 799 ≥ 800 − 1 → treated as the full-window backdrop, excluded. The
        // epsilon absorbs a backdrop that measures fractionally under the
        // window (e.g. 799.67 from safe-area rounding).
        let excluded = frontmostInsetScrollIndex(
            frames: [CGRect(x: 0, y: 0, width: 400, height: 799)],
            containing: point, windowHeight: windowHeight
        )
        #expect(excluded == nil)
        // 798 < 800 − 1 → genuinely inset, selected.
        let included = frontmostInsetScrollIndex(
            frames: [CGRect(x: 0, y: 0, width: 400, height: 798)],
            containing: point, windowHeight: windowHeight
        )
        #expect(included == 0)
    }
}
