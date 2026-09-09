import Core
import Foundation
import SwiftUI

/// Transcript Bible links request temporary previews above Chat, preserving the underlying reader.
public enum BibleDeepLinkRouter {
    /// Return false for URLs the system should handle. Bible links are consumed even without a bus.
    /// Publish asynchronously because OpenURLAction is synchronous.
    @discardableResult
    public static func handle(url: URL, eventBus: SuperEventBus?) -> Bool {
        guard let link = BibleDeepLink(url: url) else { return false }
        guard let eventBus else {
            // Consume the link here; no system app handles this scheme in previews.
            return true
        }
        Task { await eventBus.publish(.previewRecord(reference: link.recordReference)) }
        return true
    }
}

public extension View {
    /// Install at the transcript root; non-Bible URLs retain system handling.
    func bibleDeepLinkRouting(eventBus: SuperEventBus?) -> some View {
        environment(\.openURL, OpenURLAction { url in
            if BibleDeepLinkRouter.handle(url: url, eventBus: eventBus) {
                return .handled
            }
            return .systemAction
        })
    }
}
