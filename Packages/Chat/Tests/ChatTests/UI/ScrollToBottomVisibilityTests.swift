import SwiftUI
import Testing
@testable import Chat

/// Covers the composer-safe-area geometry observed in the running shell.
struct ScrollToBottomVisibilityTests {
    @Test("a focused short response does not count the composer inset twice")
    func focusedShortResponse() {
        // Semi-expanded shell: the transcript has one point of scroll range;
        // the composer/home-indicator inset is already outside its container.
        let geometry = ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: 1),
            contentSize: CGSize(width: 402, height: 507),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 147, trailing: 0),
            containerSize: CGSize(width: 402, height: 506)
        )
        #expect(!ScrollToBottomButton.VisibilityState.isAwayFromBottom(geometry))
    }

    @Test("streaming growth reveals the control until the reader catches up")
    func streamingGrowth() {
        var geometry = ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: 500),
            contentSize: CGSize(width: 402, height: 1_000),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 147, trailing: 0),
            containerSize: CGSize(width: 402, height: 500)
        )
        #expect(!ScrollToBottomButton.VisibilityState.isAwayFromBottom(geometry))
        geometry.contentSize.height += 200
        #expect(ScrollToBottomButton.VisibilityState.isAwayFromBottom(geometry))
        geometry.contentOffset.y += 200
        #expect(!ScrollToBottomButton.VisibilityState.isAwayFromBottom(geometry))
        geometry.containerSize.height -= 150
        #expect(ScrollToBottomButton.VisibilityState.isAwayFromBottom(geometry))
    }

    @Test("short content, bottom bounce, and rounding stay hidden", arguments: [200.0, 498, 500, 501, 502])
    func contentAtBottom(contentHeight: Double) {
        let geometry = ScrollGeometry(
            contentOffset: .zero,
            contentSize: CGSize(width: 402, height: contentHeight),
            contentInsets: .init(),
            containerSize: CGSize(width: 402, height: 500)
        )
        #expect(!ScrollToBottomButton.VisibilityState.isAwayFromBottom(geometry))
    }
}
