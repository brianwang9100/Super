#if canImport(UIKit)
import Testing
import UIKit
@testable import Chat

// Horizontal nested panels have no vertical travel; treating one as the transcript
// would start resizing before the transcript reaches its edge.
@MainActor
@Suite("Content-drag transcript locator (UIKit hierarchy)")
struct OverlayContentDragHierarchyTests {
    private struct Fixture {
        // convert(_:to: nil) needs a real window to include ancestor offsets.
        let window: UIWindow
        let root: UIView
        let transcript: UIScrollView
    }

    private func makeFixture() -> Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.addSubview(root)
        let backdrop = UIScrollView(frame: root.bounds)
        backdrop.contentSize = CGSize(width: 400, height: 3000)
        root.addSubview(backdrop)
        let surface = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 700))
        root.addSubview(surface)
        let transcript = UIScrollView(frame: CGRect(x: 0, y: 16, width: 400, height: 600))
        transcript.contentSize = CGSize(width: 400, height: 2000)
        surface.addSubview(transcript)
        let row = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        transcript.addSubview(row)
        let panel = UIScrollView(frame: CGRect(x: 14, y: 100, width: 372, height: 80))
        panel.contentSize = CGSize(width: 800, height: 80)
        row.addSubview(panel)
        let monospaceContent = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 80))
        panel.addSubview(monospaceContent)
        return Fixture(window: window, root: root, transcript: transcript)
    }

    @Test("Drag starting on a nested horizontal panel arms from the transcript")
    func dragOnNestedPanelResolvesTranscript() {
        let fixture = makeFixture()
        let resolved = OverlayContentDragGesture.Coordinator.transcriptScrollView(
            in: fixture.root, at: CGPoint(x: 200, y: 250)
        )
        #expect(resolved === fixture.transcript)
    }

    @Test("Drag starting on plain row content arms from the transcript")
    func dragOnPlainRowResolvesTranscript() {
        let fixture = makeFixture()
        let resolved = OverlayContentDragGesture.Coordinator.transcriptScrollView(
            in: fixture.root, at: CGPoint(x: 200, y: 350)
        )
        #expect(resolved === fixture.transcript)
    }

    @Test("A touch reaching only the backdrop resolves to nil")
    func backdropOnlyResolvesNil() {
        let fixture = makeFixture()
        let resolved = OverlayContentDragGesture.Coordinator.transcriptScrollView(
            in: fixture.root, at: CGPoint(x: 200, y: 50)
        )
        #expect(resolved == nil)
    }

    @Test("Geometric fallback skips the nested panel under the touch")
    func fallbackSkipsNestedPanel() {
        let fixture = makeFixture()
        // Cover the transcript with non-scrolling chrome to force geometric fallback.
        let chrome = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 700))
        fixture.root.addSubview(chrome)
        let resolved = OverlayContentDragGesture.Coordinator.transcriptScrollView(
            in: fixture.root, at: CGPoint(x: 200, y: 250)
        )
        #expect(resolved === fixture.transcript)
    }
}
#endif
