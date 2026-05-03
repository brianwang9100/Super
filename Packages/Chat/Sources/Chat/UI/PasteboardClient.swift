import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Tiny indirection over the system pasteboard. Lifted to a protocol so
/// the copy state machine in ``CodeBlockCopyController`` and the
/// transcript copy buttons can be exercised from tests with a recording
/// double instead of poking at `UIPasteboard.general`.
///
/// Default-injected via `EnvironmentValues.pasteboardClient` so views
/// pick up the production implementation automatically; tests override
/// per-render with `.environment(\.pasteboardClient, ...)`.
protocol PasteboardClient: Sendable {
    /// Place `text` on the system pasteboard. Idempotent — calling twice
    /// with the same string is equivalent to calling once.
    func copy(_ text: String)
}

/// Production implementation backed by `UIPasteboard.general`. No-op on
/// non-iOS hosts so the Chat package still compiles for macOS unit tests
/// that don't link UIKit.
struct SystemPasteboardClient: PasteboardClient {
    func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// Test double that records every `copy(_:)` call. Use the `writes`
/// snapshot to assert the state machine wrote what the user tapped.
final class RecordingPasteboardClient: PasteboardClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [String] = []

    var writes: [String] {
        lock.lock(); defer { lock.unlock() }
        return _writes
    }

    func copy(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _writes.append(text)
    }
}

private struct PasteboardClientKey: EnvironmentKey {
    static let defaultValue: any PasteboardClient = SystemPasteboardClient()
}

extension EnvironmentValues {
    /// Active pasteboard client. Defaults to ``SystemPasteboardClient``;
    /// tests inject ``RecordingPasteboardClient`` (or any other double).
    var pasteboardClient: any PasteboardClient {
        get { self[PasteboardClientKey.self] }
        set { self[PasteboardClientKey.self] = newValue }
    }
}
