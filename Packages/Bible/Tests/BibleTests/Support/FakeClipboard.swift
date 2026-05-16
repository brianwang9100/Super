import os
@testable import Bible

/// A `ClipboardWriter` double that records what was written, so the view
/// model's Copy action can be asserted without touching the real device
/// pasteboard. State is lock-guarded so the type stays `Sendable`.
final class FakeClipboard: ClipboardWriter {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])

    func write(_ text: String) {
        state.withLock { $0.append(text) }
    }

    /// Every value written, in order.
    var written: [String] {
        state.withLock { $0 }
    }

    /// The most recent value written, or `nil` if nothing was written.
    var lastWritten: String? {
        state.withLock { $0.last }
    }
}
