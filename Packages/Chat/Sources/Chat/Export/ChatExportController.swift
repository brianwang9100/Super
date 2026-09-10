import Core
import Foundation

/// Owns one export job and removes its previous temporary file on restart or cancel.
@Observable
@MainActor
public final class ChatExportController {
    public enum Phase: Equatable {
        case idle
        case exporting
        /// Temporary file ready for sharing.
        case finished(url: URL, conversationCount: Int)
        case failed(message: String)
    }

    public private(set) var phase: Phase = .idle

    private let exporter: any ChatExporter
    private let clock: Clock
    private var exportTask: Task<Void, Never>?
    private var lastFileURL: URL?

    public init(exporter: any ChatExporter, clock: Clock) {
        self.exporter = exporter
        self.clock = clock
    }

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
                // Detach encoding and file I/O; an inherited main-actor task would block the UI.
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

    public func cancel() {
        exportTask?.cancel()
        cleanUpLastFile()
        phase = .idle
    }

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

    /// Await the current export task for deterministic tests; no-op if none exists.
    public func _waitForExport() async {
        await exportTask?.value
    }

    public func _setSnapshotPhase(_ phase: Phase) {
        self.phase = phase
    }
}
