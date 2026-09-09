#if canImport(UIKit)
import Foundation
import SnapshotTesting
import Testing
import UIKit
@testable import VisualTestSupport

/// Exercises baseline enforcement, optional exports, and asynchronous renderer failures.
@Suite("Visual snapshot exporter", .serialized)
@MainActor
struct VisualSnapshotExporterTests {
    @Test func exportsStableIdentityWhileComparing() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try baseline(image(), in: folder)
        #expect(verify(image(), in: folder) == nil)
        let url = folder.appendingPathComponent("output/Core_Example_example.state-light.png")
        let decoded = try #require(UIImage(data: Data(contentsOf: url))?.cgImage)
        #expect(decoded.width > 0 && decoded.height > 0)
    }

    @Test(arguments: [false, true]) func missingBaselineFailsWithoutRecording(export: Bool) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let failure = withSnapshotTesting(record: .all) {
            verify(image(), in: folder, export: export)
        }
        #expect(failure?.contains("No reference was found") == true)
        #expect(!FileManager.default.fileExists(atPath: baselineURL(in: folder).path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("output/Core_Example_example.state-light.png").path) == export)
    }

    @Test(arguments: [false, true]) func changedBaselineFailsWithoutOverwriting(export: Bool) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try baseline(image(), in: folder)
        let original = try Data(contentsOf: baselineURL(in: folder))
        let failure = withSnapshotTesting(record: .failed) {
            verify(image(.blue), in: folder, export: export)
        }
        #expect(failure != nil)
        #expect(try Data(contentsOf: baselineURL(in: folder)) == original)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("output/Core_Example_example.state-light.png").path) == export)
    }

    @Test(arguments: ["CI", "GITHUB_ACTIONS", "TEST_RUNNER_CI", "TEST_RUNNER_GITHUB_ACTIONS"])
    func ciRejectsExplicitRecording(flag: String) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let failure = verify(image(), in: folder, environment: [flag: "true", "TEST_RUNNER_VISUAL_RECORD": "1"])
        #expect(failure?.contains("forbidden in CI") == true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func ciIgnoresAmbientRecordingWhileExporting() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let failure = withSnapshotTesting(record: .all) {
            verify(image(), in: folder, environment: ["CI": "true"])
        }
        #expect(failure?.contains("No reference was found") == true)
        #expect(!FileManager.default.fileExists(atPath: baselineURL(in: folder).path))
    }

    @Test func explicitLocalRecordingCreatesAndUpdatesBaseline() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(verify(image(), in: folder, export: false, environment: ["VISUAL_RECORD": "1"]) == nil)
        #expect(verify(image(), in: folder, export: false) == nil)
        #expect(verify(image(.blue), in: folder, export: false, environment: ["TEST_RUNNER_VISUAL_RECORD": "1"]) == nil)
        #expect(verify(image(.blue), in: folder, export: false) == nil)
    }

    @Test func originalPrecisionIsRetainedAndRendererRunsOnce() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try baseline(image(), in: folder)
        let changed = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            image().draw(at: .zero)
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        var renders = 0
        let strategy = Snapshotting<UIImage, UIImage>(pathExtension: "png", diffing: .image(precision: 0.98)) { value in
            renders += 1
            return value
        }
        #expect(verify(changed, as: strategy, in: folder) == nil)
        #expect(renders == 1)
        #expect(verify(changed, in: folder, export: false) != nil)
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
        let result = verify(image(), as: strategy, in: folder, timeout: 0.01)
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
        #expect(verify(image(), as: strategy, in: folder)?.contains("repeated capture completion") == true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func offMainCompletionIsSynchronized() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try baseline(image(), in: folder)
        let strategy = Snapshotting<UIImage, UIImage>(pathExtension: "png", diffing: .image, asyncSnapshot: { value in
            Async { callback in
                let delivery = Callback()
                delivery.complete = callback
                Thread.detachNewThread { delivery.complete?(value) }
            }
        })
        #expect(verify(image(), as: strategy, in: folder) == nil)
    }

    private func verify(
        _ image: UIImage,
        as strategy: Snapshotting<UIImage, UIImage> = .image,
        in folder: URL,
        timeout: TimeInterval = 5,
        export: Bool = true,
        environment: [String: String] = [:]
    ) -> String? {
        var environment = environment
        if export { environment["TEST_RUNNER_SNAPSHOT_OUTPUT_DIR"] = folder.appendingPathComponent("output").path }
        return verifyVisualSnapshot(
            of: image, as: strategy, named: "state light", timeout: timeout,
            environment: environment, baselineDirectory: folder.appendingPathComponent("baseline"),
            fileID: "CoreTests/Example.swift", file: "/Example.swift", testName: "example()"
        )
    }

    private func baseline(_ image: UIImage, in folder: URL) throws {
        try VisualSnapshotExporter.write(image, named: baselineURL(in: folder).lastPathComponent,
                                         to: folder.appendingPathComponent("baseline"))
    }

    private func baselineURL(in folder: URL) -> URL {
        folder.appendingPathComponent("baseline/example.state-light.png")
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
