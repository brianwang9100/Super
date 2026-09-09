#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public protocol ClipboardWriter: Sendable {
    /// Replaces clipboard contents with plain text.
    func write(_ text: String)
}

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
