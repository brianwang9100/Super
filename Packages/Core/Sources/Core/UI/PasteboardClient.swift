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
public protocol PasteboardClient: Sendable {
    /// Place `text` on the system pasteboard. Idempotent — calling twice
    /// with the same string is equivalent to calling once.
    func copy(_ text: String)
}

/// Production implementation backed by `UIPasteboard.general`. No-op on
/// non-iOS hosts so this package still compiles for macOS unit-test runs
/// that don't link UIKit.
public struct SystemPasteboardClient: PasteboardClient {
    public init() {}

    public func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

private struct PasteboardClientKey: EnvironmentKey {
    static let defaultValue: any PasteboardClient = SystemPasteboardClient()
}

public extension EnvironmentValues {
    /// Active pasteboard client. Defaults to ``SystemPasteboardClient``;
    /// tests inject a recording double (see CoreTests'
    /// `RecordingPasteboardClient`).
    var pasteboardClient: any PasteboardClient {
        get { self[PasteboardClientKey.self] }
        set { self[PasteboardClientKey.self] = newValue }
    }
}
