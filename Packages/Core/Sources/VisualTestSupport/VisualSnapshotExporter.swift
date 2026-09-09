#if canImport(UIKit)
import Foundation
import os
import SnapshotTesting
import UIKit
import XCTest

/// Capture failures are test failures; none can be treated as a reviewed visual baseline.
public enum VisualCaptureError: Error, Sendable {
    case invalidIdentity
    case invalidImage
    case duplicateCapture(String)
    case writeFailed(String)
}

/// Writes test-only images without reading or recording repository baselines.
@MainActor
public enum VisualSnapshotExporter {
    /// Keeps the previous suite/test/name identity, prefixed by its owning package.
    public static func filename(fileID: String, file: String, testName: String, name: String) throws -> String {
        let module = fileID.split(separator: "/").first.map(String.init) ?? ""
        guard module.hasSuffix("Tests") else { throw VisualCaptureError.invalidIdentity }
        let package = String(module.dropLast(5))
        let suite = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let components = [package, suite, testName, name].map(sanitized)
        guard components.allSatisfy({ !$0.isEmpty }) else { throw VisualCaptureError.invalidIdentity }
        return "\(components[0])_\(components[1])_\(components[2]).\(components[3]).png"
    }

    static func sanitized(_ component: String) -> String {
        component.replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
    }

    /// Exclusive creation makes duplicate identities fail instead of overwriting a capture.
    public static func write(_ image: UIImage, named name: String, to directory: URL) throws {
        guard directory.isFileURL, name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasSuffix(".png") else { throw VisualCaptureError.invalidIdentity }
        guard let bitmap = image.cgImage, bitmap.width > 0, bitmap.height > 0,
              let data = image.pngData(), !data.isEmpty, UIImage(data: data)?.cgImage != nil else {
            throw VisualCaptureError.invalidImage
        }
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .withoutOverwriting)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                throw VisualCaptureError.duplicateCapture(name)
            }
            throw VisualCaptureError.writeFailed(String(describing: error))
        }
    }
}

/// Compares a single render against its repository baseline, optionally exporting the same image.
/// Only explicit local `VISUAL_RECORD=1` updates baselines; CI always rejects recording.
@MainActor
public func verifyVisualSnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as strategy: Snapshotting<Value, UIImage>,
    named name: String,
    timeout: TimeInterval = 5,
    fileID: StaticString = #fileID,
    file: StaticString = #filePath,
    testName: String = #function
) -> String? {
    verifyVisualSnapshot(
        of: try value(), as: strategy, named: name, timeout: timeout,
        environment: ProcessInfo.processInfo.environment,
        fileID: fileID, file: file, testName: testName
    )
}

// Internal injection is only for exporter regressions. Production callers cannot opt out of comparison.
@MainActor
func verifyVisualSnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as strategy: Snapshotting<Value, UIImage>,
    named name: String,
    timeout: TimeInterval = 5,
    environment: [String: String],
    baselineDirectory: URL? = nil,
    fileID: StaticString = #fileID,
    file: StaticString = #filePath,
    testName: String = #function
) -> String? {
    guard !captureInProgress else { return "Overlapping UIKit captures; run visual suites serially" }
    captureInProgress = true
    defer { captureInProgress = false }
    do {
        func setting(_ key: String) -> String? {
            environment[key] ?? environment["TEST_RUNNER_\(key)"]
        }
        func enabled(_ key: String) -> Bool {
            [environment[key], environment["TEST_RUNNER_\(key)"]]
                .contains { ["1", "true", "yes"].contains($0?.lowercased() ?? "") }
        }
        let recording = setting("VISUAL_RECORD") == "1"
        guard !recording || !(enabled("CI") || enabled("GITHUB_ACTIONS")) else {
            return "Visual recording is forbidden in CI"
        }
        let filename = try VisualSnapshotExporter.filename(
            fileID: fileID.description, file: file.description, testName: testName, name: name
        )
        let output: URL?
        if let configured = setting("SNAPSHOT_OUTPUT_DIR") {
            guard configured.hasPrefix("/") else { return "SNAPSHOT_OUTPUT_DIR must be an absolute directory" }
            output = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            output = nil
        }
        let completion = XCTestExpectation(description: "Render \(filename)")
        let result = CaptureResult()
        strategy.snapshot(try value()).run { @Sendable image in
            if result.receive(image) { completion.fulfill() }
        }
        let wait = XCTWaiter.wait(for: [completion], timeout: timeout)
        let state = result.finish()
        guard wait == .completed else { return "Capture did not complete within \(timeout) seconds: \(filename)" }
        guard state.callbacks == 1, let image = state.image else { return "Invalid or repeated capture completion: \(filename)" }
        guard let bitmap = image.cgImage, bitmap.width > 0, bitmap.height > 0 else {
            throw VisualCaptureError.invalidImage
        }
        if let output { try VisualSnapshotExporter.write(image, named: filename, to: output) }

        let source = URL(fileURLWithPath: file.description)
        let suite = source.deletingPathExtension().lastPathComponent
        let baseline = baselineDirectory ?? source.deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true)
        // Reuse the exporter's sanitized identity, including its distinct parameterized state names.
        let identity = "\(VisualSnapshotExporter.sanitized(testName)).\(VisualSnapshotExporter.sanitized(name)).png"
        if recording {
            try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: true)
            try strategy.diffing.toData(image).write(to: baseline.appendingPathComponent(identity), options: .atomic)
            return nil
        }
        // Preserve the fixture's original precision/perceptual tolerances; never render a second time.
        let rendered = Snapshotting<UIImage, UIImage>(pathExtension: "png", diffing: strategy.diffing, snapshot: { $0 })
        return withSnapshotTesting(record: .never) {
            verifySnapshot(
                of: image, as: rendered, named: name, record: .never,
                snapshotDirectory: baseline.path, timeout: timeout,
                fileID: fileID, file: file, testName: testName
            )
        }
    } catch {
        return "Visual snapshot failed: \(error)"
    }
}

@MainActor private var captureInProgress = false

/// Callback state is synchronized even when an asynchronous strategy completes off the main thread.
private final class CaptureResult: @unchecked Sendable {
    struct State {
        var accepting = true
        var callbacks = 0
        var image: UIImage?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ image: UIImage) -> Bool {
        state.withLock { value in
            guard value.accepting else { return false }
            value.callbacks += 1
            if value.callbacks == 1 { value.image = image }
            return value.callbacks == 1
        }
    }

    func finish() -> State {
        state.withLock { value in
            value.accepting = false
            return value
        }
    }
}
#endif
