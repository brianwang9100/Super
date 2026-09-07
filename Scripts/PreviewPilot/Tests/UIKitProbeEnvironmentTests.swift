import UIKit
import XCTest
@testable import Core

/// Proves that a reused simulator's accessibility text size cannot alter the UIKit probes.
@MainActor
final class UIKitProbeEnvironmentTests: XCTestCase {
    func testCollectionPinsTextSizeUnderAccessibilityParent() {
        assertDefaultTextSize(PreviewCollectionController())
    }

    func testFontPanelPinsTextSizeUnderAccessibilityParent() {
        assertDefaultTextSize(makePreviewFontPanelController())
    }

    private func assertDefaultTextSize(_ child: UIViewController) {
        let parent = UIViewController()
        parent.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        XCTAssertEqual(parent.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
        XCTAssertEqual(child.traitCollection.preferredContentSizeCategory, .large)
    }
}
