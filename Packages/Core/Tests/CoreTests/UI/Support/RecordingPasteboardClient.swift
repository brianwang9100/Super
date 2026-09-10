import Core
import Synchronization

final class RecordingPasteboardClient: PasteboardClient, Sendable {
    private let _writes = Mutex<[String]>([])

    var writes: [String] {
        _writes.withLock { $0 }
    }

    func copy(_ text: String) {
        _writes.withLock { $0.append(text) }
    }
}
