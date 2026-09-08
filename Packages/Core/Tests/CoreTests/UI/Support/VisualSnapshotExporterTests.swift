#if canImport(UIKit)
import Foundation
import SnapshotTesting
import Testing
import UIKit
import VisualTestSupport

/// Exercises capture publication and callback failures without repository baselines.
@Suite("Visual snapshot exporter", .serialized)
@MainActor
struct VisualSnapshotExporterTests {
    @Test func exportsIdentityWithoutReadingABaseline() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = verifyVisualSnapshot(of: image(), as: .image, named: "state light", directory: folder,
                                          fileID: "CoreTests/Example.swift", file: "/Example.swift", testName: "example()")
        #expect(result == nil)
        let url = folder.appendingPathComponent("Core_Example_example.state-light.png")
        let decoded = try #require(UIImage(data: Data(contentsOf: url))?.cgImage)
        #expect(decoded.width > 0 && decoded.height > 0)
    }

    @Test func duplicateIdentityCannotOverwrite() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try VisualSnapshotExporter.write(image(), named: "same.png", to: folder)
        let original = try Data(contentsOf: folder.appendingPathComponent("same.png"))
        #expect(throws: VisualCaptureError.self) {
            try VisualSnapshotExporter.write(image(.blue), named: "same.png", to: folder)
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent("same.png")) == original)
    }

    @Test func invalidImageAndWriteDestinationFail() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: VisualCaptureError.self) {
            try VisualSnapshotExporter.write(UIImage(), named: "empty.png", to: folder)
        }
        try Data([1]).write(to: folder)
        #expect(throws: VisualCaptureError.self) {
            try VisualSnapshotExporter.write(image(), named: "blocked.png", to: folder)
        }
    }

    @Test func timeoutNeverPublishesLateCompletion() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let callback = Callback()
        let strategy = Snapshotting<UIImage, UIImage>(pathExtension: "png", diffing: .image, asyncSnapshot: { _ in
            Async { callback.complete = $0 }
        })
        let result = verifyVisualSnapshot(of: image(), as: strategy, named: "late", timeout: 0.01, directory: folder)
        #expect(result?.contains("did not complete") == true)
        callback.complete?(image())
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func duplicateCompletionFailsWithoutPublishing() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let strategy = Snapshotting<UIImage, UIImage>(pathExtension: "png", diffing: .image, asyncSnapshot: { value in
            Async { callback in callback(value); callback(value) }
        })
        let result = verifyVisualSnapshot(of: image(), as: strategy, named: "twice", directory: folder)
        #expect(result?.contains("repeated capture completion") == true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func offMainCompletionIsSynchronized() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let strategy = Snapshotting<UIImage, UIImage>(pathExtension: "png", diffing: .image, asyncSnapshot: { value in
            Async { callback in
                let delivery = Callback()
                delivery.complete = callback
                Thread.detachNewThread { delivery.complete?(value) }
            }
        })
        #expect(verifyVisualSnapshot(of: image(), as: strategy, named: "background", directory: folder) == nil)
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func image(_ color: UIColor = .red) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
}

/// A test-owned callback is published before its background thread starts.
private final class Callback: @unchecked Sendable {
    var complete: ((UIImage) -> Void)?
}
#endif
