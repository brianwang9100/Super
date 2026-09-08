import SwiftUI
import UIKit
import XCTest
@testable import SnapshotPreviewsCore

/// Samples the actual system spinner at different elapsed times to detect accidental phase agreement.
@MainActor
final class RendererStabilityTests: XCTestCase {
    func testSpinnerRemainsVisibleAndRepeatableAcrossElapsedTime() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let content = ProgressView().tint(.black).frame(width: 64, height: 64).background(.white)
        let controller = content.makeExpandingView(layout: .fixed(width: 64, height: 64), window: window)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let first = try await capture(content, controller: controller, window: window)
        try await Task.sleep(for: .milliseconds(650))
        let second = try await capture(content, controller: controller, window: window)
        XCTAssertEqual(first.pngData(), second.pngData(), "Spinner phase must not depend on capture delay")
        let bitmap = try XCTUnwrap(first.cgImage)
        XCTAssertEqual(bitmap.bitsPerComponent, 8, "Capture must use an explicit standard color range")
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let inkCount = try pixels.withUnsafeMutableBytes { buffer -> Int in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0 + 3] > 0 && min(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) < 200
            }.count
        }
        XCTAssertGreaterThan(inkCount, 20, "A paused spinner must remain visible, not just repeat as blank")
        XCTAssertLessThan(inkCount, bitmap.width * bitmap.height / 2, "The expected white background must remain visible")
    }

    private func capture<V: View>(_ content: V, controller: ExpandingViewController, window: UIWindow) async throws -> UIImage {
        let finished = expectation(description: "Native capture completes")
        var result: Result<UIImage, Error>?
        content.snapshot(layout: .fixed(width: 64, height: 64), controller: controller, window: window, async: false) {
            result = $0.image
            finished.fulfill()
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await fulfillment(of: [finished], timeout: 5)
        return try XCTUnwrap(result).get()
    }
}
