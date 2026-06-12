import Core
import Synchronization

/// Test double that records every `copy(_:)` call. Use the `writes`
/// snapshot to assert the state machine wrote what the user tapped.
///
/// State is protected by ``Synchronization/Mutex`` per AGENTS.md
/// §Swift Concurrency ("Never use `DispatchQueue` or `NSLock` for
/// synchronization"), which also makes the class `Sendable` without
/// `@unchecked`.
final class RecordingPasteboardClient: PasteboardClient, Sendable {
    private let _writes = Mutex<[String]>([])

    var writes: [String] {
        _writes.withLock { $0 }
    }

    func copy(_ text: String) {
        _writes.withLock { $0.append(text) }
    }
}
