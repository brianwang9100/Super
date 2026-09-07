import SwiftUI
import XCTest
@testable import SnapshotPreviewsCore

/// Regression coverage for fixed viewports and the minimum intrinsic fitting contract.
@MainActor
final class RendererLayoutTests: XCTestCase {
    func testFixedViewportDisablesExpansionAndResetRestoresIt() {
        let controller = ExpandingViewController(rootView: ScrollView {
            VStack { ForEach(0..<12) { _ in Color.red.frame(height: 48) } }
        })
        controller.setupView(layout: .fixed(width: 402, height: 180))
        XCTAssertFalse(controller.supportsExpansion)
        XCTAssertEqual(controller.heightAnchor?.constant, 180)
        controller.setupView(layout: .sizeThatFits)
        XCTAssertTrue(controller.supportsExpansion)
    }

    func testSizeThatFitsUsesMinimumProposalAndPreservesFractionalHeight() {
        let controller = ExpandingViewController(rootView: ProposalSensitiveLayout { Color.red })
        controller.setupView(layout: .sizeThatFits)
        XCTAssertEqual(controller.heightAnchor?.constant ?? 0, 352.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(controller.heightAnchor?.relation, .equal)
    }
}

/// Makes a full-screen proposal observably different from the minimum fitting proposal.
private struct ProposalSensitiveLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: 402, height: proposal.height == 0 ? 352.0 / 3 : 118)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
