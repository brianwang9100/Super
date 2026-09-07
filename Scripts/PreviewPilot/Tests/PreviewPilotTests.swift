import Core
import SnapshottingTests
import UIKit
import XCTest

/// Exports only the ChatComposer matrix and Core's UIKit proof, never the legacy suites.
final class PreviewPilotTests: SnapshotTest {
    override class func snapshotPreviewModules() -> [String]? { ["Chat", "Core"] }

    override class func snapshotPreviews() -> [String]? {
        [
            "^Chat/ChatComposerPreviews.swift:composer_.*$",
            "^Core/PreviewCollectionController.swift:(collection_viewport_light|font_panel_light)$",
        ]
    }

    override func setUp() async throws {
        await MainActor.run {
            Core.registerBundledFonts()
            for face in [
                "EBGaramond-Regular", "EBGaramond-Italic", "EBGaramond-SemiBold",
                "EBGaramond-SemiBoldItalic", "JetBrainsMono-Regular",
            ] {
                XCTAssertNotNil(UIFont(name: face, size: 20), "Missing bundled font: \(face)")
            }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            XCTAssertEqual(scene?.screen.scale, 3)
        }
    }
}
