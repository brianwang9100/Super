#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Writes plain text to the system clipboard.
///
/// A seam over the platform pasteboard so the reader's Copy action is
/// testable — tests substitute a recording double rather than mutating the
/// real device clipboard.
public protocol ClipboardWriter: Sendable {
    /// Replace the clipboard's contents with `text`.
    func write(_ text: String)
}

/// `ClipboardWriter` backed by the platform pasteboard — `UIPasteboard` on
/// iOS, `NSPasteboard` on macOS (the latter only for `swift test` builds).
public struct SystemClipboard: ClipboardWriter {
    public init() {}

    public func write(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
