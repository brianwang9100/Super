#if canImport(UIKit)
import Testing
import UIKit
@testable import Chat

/// UIKit view-hierarchy tests for the content-drag locator —
/// `OverlayContentDragGesture.Coordinator.transcriptScrollView(in:at:)`. The
/// drag → resize handoff must always arm from the **transcript** scroll view:
/// never a nested horizontal panel (tool-call INPUT/RESULT, markdown code
/// block) and never the full-window backdrop applet.
///
/// Regression surface for the premature-minimize bug: a drag starting on an
/// expanded tool/thinking block's horizontal panel used to resolve the
/// *nearest* enclosing scroll view (the panel), whose vertical geometry reads
/// "not scrollable" — arming an immediate resize from mid-transcript. The
/// hierarchy mirrors production structure with plain frame-laid-out `UIView`s
/// inside a real `UIWindow` (the locator's `convert(_:to: nil)` needs window
/// membership; hit-testing itself is frame-based, no rendering). Runs on the
/// iOS simulator only — compiles out under `swift test` on macOS, like the
/// other UIKit-gated suites in this directory (`MessageListDeclarativeScrollTests`).
@MainActor
@Suite("Content-drag transcript locator (UIKit hierarchy)")
struct OverlayContentDragHierarchyTests {
    /// Production-shaped view tree: a full-window backdrop scroll view (the
    /// applet behind the chat), the chat surface inset below the handle
    /// chrome, the transcript scroll view inside it, and a row hosting a
    /// nested horizontal monospace panel — `ToolCallBlock`'s expanded shape.
    private struct Fixture {
        /// The hierarchy must live in a real `UIWindow`: the locator converts
        /// frames with `convert(_:to: nil)` (window base coordinates), which
        /// only folds ancestor offsets when a window is present. A detached
        /// tree silently yields superview-relative frames and the geometry
        /// assertions test the wrong thing.
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
        // Chat surface inset below the drag handle / header, as in production
        // (the transcript is never full-window).
        let surface = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 700))
        root.addSubview(surface)
        let transcript = UIScrollView(frame: CGRect(x: 0, y: 16, width: 400, height: 600))
        transcript.contentSize = CGSize(width: 400, height: 2000)
        surface.addSubview(transcript)
        let row = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        transcript.addSubview(row)
        // Horizontal monospace panel: wide content, no vertical travel.
        let panel = UIScrollView(frame: CGRect(x: 14, y: 100, width: 372, height: 80))
        panel.contentSize = CGSize(width: 800, height: 80)
        row.addSubview(panel)
        let monospaceContent = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 80))
        panel.addSubview(monospaceContent)
        return Fixture(window: window, root: root, transcript: transcript)
    }

    /// The bug's exact shape: the finger lands on the nested horizontal panel
    /// (root coordinates — surface 100 + transcript 16 + panel 100 = y 216).
    /// The locator must climb past the panel to the transcript.
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
        // (200, 350) is inside the row but outside the panel (panel spans
        // y 216–296 in root coordinates).
        let resolved = OverlayContentDragGesture.Coordinator.transcriptScrollView(
            in: fixture.root, at: CGPoint(x: 200, y: 350)
        )
        #expect(resolved === fixture.transcript)
    }

    /// Above the chat surface only the full-window backdrop is under the
    /// touch: the locator must resolve to nothing (the caller drives the
    /// resize immediately — the empty-state path), never the backdrop.
    @Test("A touch reaching only the backdrop resolves to nil")
    func backdropOnlyResolvesNil() {
        let fixture = makeFixture()
        let resolved = OverlayContentDragGesture.Coordinator.transcriptScrollView(
            in: fixture.root, at: CGPoint(x: 200, y: 50)
        )
        #expect(resolved == nil)
    }

    /// Keyboard-up shape: the hit-test resolves to non-scrolling chrome over
    /// the transcript, so the locator falls back to geometry. The fallback
    /// must pick the transcript even when the touch point also lies inside
    /// the nested panel's frame.
    @Test("Geometric fallback skips the nested panel under the touch")
    func fallbackSkipsNestedPanel() {
        let fixture = makeFixture()
        // Frontmost chrome covering the whole surface: hit-test lands here,
        // and it has no enclosing scroll view.
        let chrome = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 700))
        fixture.root.addSubview(chrome)
        let resolved = OverlayContentDragGesture.Coordinator.transcriptScrollView(
            in: fixture.root, at: CGPoint(x: 200, y: 250)
        )
        #expect(resolved === fixture.transcript)
    }
}
#endif
