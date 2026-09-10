import os
@testable import Bible

final class FakeClipboard: ClipboardWriter {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])

    func write(_ text: String) {
        state.withLock { $0.append(text) }
    }

    var written: [String] {
        state.withLock { $0 }
    }

    var lastWritten: String? {
        state.withLock { $0.last }
    }
}
