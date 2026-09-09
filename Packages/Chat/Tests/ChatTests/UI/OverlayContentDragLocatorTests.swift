import Foundation
import Testing
@testable import Chat

@Suite("Content-drag scroll-view locator geometry")
struct OverlayContentDragLocatorTests {
    private let windowHeight: CGFloat = 800

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
        #expect(index == nil)
    }

    @Test("A tall inset transcript reaching the bottom edge is still selected")
    func tallInsetTranscriptStillSelected() {
        // Covering the bottom is valid; only full top-to-bottom coverage identifies the backdrop.
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
        #expect(coversWindowVertically(backdrop, windowHeight: windowHeight))
        #expect(coversWindowVertically(
            CGRect(x: 0, y: 0.5, width: 400, height: 799.3), windowHeight: windowHeight
        ))
        #expect(!coversWindowVertically(
            CGRect(x: 0, y: 116, width: 400, height: 684), windowHeight: windowHeight
        ))
        #expect(!coversWindowVertically(
            CGRect(x: 0, y: 60, width: 400, height: 740), windowHeight: windowHeight
        ))
    }

    // MARK: - outermostInsetScrollIndex (hit-test chain pick)

    @Test("Chain pick: the transcript wins over a nested horizontal panel")
    func chainPicksOutermostInsetOverNestedPanel() {
        let panel = CGRect(x: 14, y: 480, width: 372, height: 60)
        let index = outermostInsetScrollIndex(
            chainFrames: [panel, transcript], windowHeight: windowHeight
        )
        #expect(index == 1)
    }

    @Test("Chain pick: a lone transcript resolves to itself")
    func chainLoneTranscript() {
        let index = outermostInsetScrollIndex(
            chainFrames: [transcript], windowHeight: windowHeight
        )
        #expect(index == 0)
    }

    @Test("Chain pick: only the full-window backdrop in the chain → nil")
    func chainBackdropOnlyIsNil() {
        let index = outermostInsetScrollIndex(
            chainFrames: [backdrop], windowHeight: windowHeight
        )
        #expect(index == nil)
    }

    @Test("Chain pick: outermost *inset*, not outermost overall")
    func chainSkipsFullWindowAncestor() {
        let panel = CGRect(x: 14, y: 480, width: 372, height: 60)
        let index = outermostInsetScrollIndex(
            chainFrames: [panel, transcript, backdrop], windowHeight: windowHeight
        )
        #expect(index == 1)
    }

    @Test("Chain pick: empty chain → nil")
    func chainEmptyIsNil() {
        #expect(outermostInsetScrollIndex(chainFrames: [], windowHeight: windowHeight) == nil)
    }

    @Test("Full-window exclusion uses a 1-point epsilon for backdrop rounding")
    func fullWindowEpsilon() {
        let point = CGPoint(x: 200, y: 400)
        // Tolerate sub-point rounding when excluding a full-window backdrop.
        let excluded = frontmostInsetScrollIndex(
            frames: [CGRect(x: 0, y: 0, width: 400, height: 799)],
            containing: point, windowHeight: windowHeight
        )
        #expect(excluded == nil)
        let included = frontmostInsetScrollIndex(
            frames: [CGRect(x: 0, y: 0, width: 400, height: 798)],
            containing: point, windowHeight: windowHeight
        )
        #expect(included == 0)
    }
}
