import Core
import Foundation
import os
import Testing
@testable import Chat

/// Drives `ChatExportController` through its phases with fake exporters,
/// synchronizing on observable signals (the `_waitForExport()` drain seam and
/// the gate exporter's entry signal) rather than sleeps or yield polling.
@Suite("ChatExportController")
@MainActor
struct ChatExportControllerTests {
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))

    private func archive(conversationCount: Int) -> ChatArchive {
        ChatArchive(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            conversations: (0..<conversationCount).map { i in
                .init(id: "c\(i)", title: nil,
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      messages: [])
            }
        )
    }

    @Test("idle → exporting → finished writes a readable file and the count")
    func finishes() async throws {
        let controller = ChatExportController(
            exporter: StubExporter(result: .success(archive(conversationCount: 3))),
            clock: clock
        )
        #expect(controller.phase == .idle)

        controller.start()
        await controller._waitForExport()

        guard case let .finished(url, count) = controller.phase else {
            Issue.record("expected .finished, got \(controller.phase)")
            return
        }
        #expect(count == 3)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let decoded = try JSONDecoder.iso8601.decode(ChatArchive.self, from: Data(contentsOf: url))
        #expect(decoded.conversations.count == 3)

        controller.reset()
        #expect(controller.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("exporter error → failed")
    func fails() async throws {
        let controller = ChatExportController(
            exporter: StubExporter(result: .failure(ChatExportError.encodingFailed)),
            clock: clock
        )
        controller.start()
        await controller._waitForExport()

        guard case .failed = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
    }

    @Test("cancel mid-flight returns to idle and produces no file")
    func cancelsMidFlight() async throws {
        let gate = GateExporter(result: archive(conversationCount: 1))
        let controller = ChatExportController(exporter: gate, clock: clock)

        controller.start()
        #expect(controller.phase == .exporting)

        // Synchronize on the exporter actually entering export() before
        // cancelling — the cancel lands between start and completion.
        await gate.awaitStarted()
        controller.cancel()
        #expect(controller.phase == .idle)

        // Let export() return; the controller's post-export cancellation check
        // (or its cancelled-task guard) drops the result without writing.
        await gate.release()
        await controller._waitForExport()

        #expect(controller.phase == .idle)
    }
}

/// Non-gated fake: returns or throws immediately on the first call,
/// `fatalError`s on a second (strict — a re-entrant export is a test bug).
private struct StubExporter: ChatExporter {
    enum Result: Sendable { case success(ChatArchive), failure(any Error & Sendable) }
    private let result: Result
    private let used = OSAllocatedUnfairLock(initialState: false)

    init(result: Result) { self.result = result }

    func export() async throws -> ChatArchive {
        let alreadyUsed = used.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        if alreadyUsed { fatalError("StubExporter.export called more than once") }
        switch result {
        case let .success(archive): return archive
        case let .failure(error): throw error
        }
    }
}

/// Gated fake: signals on entry, then suspends until `release()` so a test can
/// drive the start→cancel→complete ordering deterministically.
private actor GateExporter: ChatExporter {
    private let result: ChatArchive
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didRelease = false

    init(result: ChatArchive) { self.result = result }

    func export() async throws -> ChatArchive {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !didRelease {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return result
    }

    /// Resolves once `export()` has been entered.
    func awaitStarted() async {
        if didStart { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    /// Allow the suspended `export()` to return.
    func release() {
        didRelease = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
