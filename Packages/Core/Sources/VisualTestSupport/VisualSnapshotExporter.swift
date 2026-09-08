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
        let components = [package, suite, testName, name].map {
            $0.replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
                .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
        }
        guard components.allSatisfy({ !$0.isEmpty }) else { throw VisualCaptureError.invalidIdentity }
        return "\(components[0])_\(components[1])_\(components[2]).\(components[3]).png"
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

/// Renders an existing image strategy and returns an error for the calling Swift Testing assertion.
/// No diffing strategy, local baseline, or recording mode participates in this operation.
@MainActor
public func verifyVisualSnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as strategy: Snapshotting<Value, UIImage>,
    named name: String,
    timeout: TimeInterval = 5,
    directory: URL? = nil,
    fileID: String = #fileID,
    file: String = #filePath,
    testName: String = #function
) -> String? {
    guard !captureInProgress else { return "Overlapping UIKit captures; run visual suites serially" }
    captureInProgress = true
    defer { captureInProgress = false }
    do {
        let filename = try VisualSnapshotExporter.filename(fileID: fileID, file: file, testName: testName, name: name)
        let destination: URL
        if let directory {
            destination = directory
        } else if let configured = ProcessInfo.processInfo.environment["ARGOS_OUTPUT_DIR"] {
            guard configured.hasPrefix("/") else { return "ARGOS_OUTPUT_DIR must be an absolute directory" }
            destination = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("SuperVisualCaptures-\(ProcessInfo.processInfo.processIdentifier)")
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
        try VisualSnapshotExporter.write(image, named: filename, to: destination)
        return nil
    } catch {
        return "Visual capture failed: \(error)"
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
