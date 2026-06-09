import Core
import Foundation

/// Drives the Data pane's export job: a cancellable background `Task` that
/// builds the archive, writes it to a temporary `.json` file, and exposes the
/// resulting URL for the share flow.
///
/// Lifted out of the SwiftUI view (the ``CodeBlockCopyController`` pattern) so
/// the start/cancel/finish state machine is testable without a render. The
/// controller owns exactly one in-flight export; starting again cancels any
/// prior task and removes the previous temp file.
@Observable
@MainActor
public final class ChatExportController {
    /// Where the export job is in its lifecycle.
    public enum Phase: Equatable {
        case idle
        case exporting
        /// Archive written and ready to share. `url` is a temporary file;
        /// `conversationCount` drives the "N chats" affordance copy.
        case finished(url: URL, conversationCount: Int)
        /// The job threw. `message` is user-facing.
        case failed(message: String)
    }

    public private(set) var phase: Phase = .idle

    private let exporter: any ChatExporter
    private let clock: Clock
    private var exportTask: Task<Void, Never>?
    /// The temp file produced by the most recent successful run, tracked so a
    /// re-export or cancel can clean it up.
    private var lastFileURL: URL?

    public init(exporter: any ChatExporter, clock: Clock) {
        self.exporter = exporter
        self.clock = clock
    }

    /// Begin an export. No-op while one is already running. Cancels any prior
    /// finished/failed run's temp file before starting fresh.
    public func start() {
        guard phase != .exporting else { return }
        cleanUpLastFile()
        phase = .exporting
        let exporter = self.exporter
        let clock = self.clock
        exportTask = Task { [weak self] in
            do {
                let archive = try await exporter.export()
                try Task.checkCancellation()
                // Encode + write off the main actor: this Task inherits
                // @MainActor from `start()`, and a large archive would
                // otherwise block the main thread on the JSON encode + file
                // write. `ChatArchive`/`URL`/`Date` are Sendable.
                let url = try await Task.detached(priority: .utility) {
                    try Self.writeTempFile(archive.encoded(), now: clock.now())
                }.value
                guard let self, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.lastFileURL = url
                self.phase = .finished(url: url, conversationCount: archive.conversations.count)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(message: Self.message(for: error))
            }
        }
    }

    /// Cancel an in-flight export and return to idle. Safe to call in any
    /// phase.
    public func cancel() {
        exportTask?.cancel()
        cleanUpLastFile()
        phase = .idle
    }

    /// Drop the finished/failed state back to idle so the pane re-offers
    /// "Export all chats". Removes the prior temp file.
    public func reset() {
        cleanUpLastFile()
        phase = .idle
    }

    private func cleanUpLastFile() {
        if let lastFileURL {
            try? FileManager.default.removeItem(at: lastFileURL)
            self.lastFileURL = nil
        }
    }

    /// Write `data` to a uniquely-named file in the temporary directory.
    /// `nonisolated` so the encode + write can run off the main actor.
    private nonisolated static func writeTempFile(_ data: Data, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "super-chats-\(formatter.string(from: now)).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ChatExportError.fileWriteFailed
        }
        return url
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case ChatExportError.encodingFailed:
            return "Could not encode your chats."
        case ChatExportError.fileWriteFailed:
            return "Could not write the export file."
        default:
            return "Export failed. Please try again."
        }
    }

    /// Test seam: await the most recent export task so a test asserts the
    /// resulting phase on an observable signal rather than polling. No-op when
    /// no export is in flight. Underscore-prefixed — test-only, not API.
    public func _waitForExport() async {
        await exportTask?.value
    }

    /// Test/snapshot seam: force a phase without running a job, so the Data
    /// pane can be rendered in each visual state. Underscore-prefixed —
    /// test-only, not API.
    public func _setSnapshotPhase(_ phase: Phase) {
        self.phase = phase
    }
}
