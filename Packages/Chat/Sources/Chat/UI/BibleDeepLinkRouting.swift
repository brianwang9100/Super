import Core
import Foundation
import SwiftUI

/// Routes `super://bible/verse?...` URL taps from the rendered chat
/// transcript onto the cross-applet event bus. The Bible applet
/// (subscribed on the same bus) receives a `SuperEvent.openRecord`
/// payload and navigates the reader to the verses; the shell also
/// subscribes so it can swap the active applet under the chat overlay
/// first. External `https://...` links keep their existing system
/// behaviour — they fall through to Safari.
///
/// The pure routing logic is exposed via ``BibleDeepLinkRouter`` so
/// unit tests don't need a SwiftUI host to verify the event the tap
/// produces. ``View/bibleDeepLinkRouting(eventBus:)`` is the SwiftUI
/// wrapper that the chat transcript actually installs.
public enum BibleDeepLinkRouter {
    /// Try to route `url` through the Bible deep-link path. Returns
    /// `true` iff `url` parsed as a `super://bible/verse?...` URL and
    /// a publish was scheduled on `eventBus`. Returns `false` for any
    /// other URL — caller should fall through to system handling so
    /// `https://...` keeps opening in Safari.
    ///
    /// The publish is fire-and-forget through an unstructured `Task`
    /// because SwiftUI's `OpenURLAction` closure is synchronous; if
    /// `eventBus` is `nil` (no bus injected, e.g. snapshot host) the
    /// URL is reported handled so the system doesn't try to open the
    /// nonexistent scheme.
    @discardableResult
    public static func handle(url: URL, eventBus: SuperEventBus?) -> Bool {
        guard let link = BibleDeepLink(url: url) else { return false }
        guard let eventBus else {
            // Bus-less context (preview, snapshot host) — swallow the
            // tap so SwiftUI doesn't kick the URL out to the system
            // with no app registered to receive it.
            return true
        }
        Task { await eventBus.publish(.openRecord(reference: link.recordReference)) }
        return true
    }
}

public extension View {
    /// Install an `OpenURLAction` on this subtree that intercepts
    /// `super://bible/verse?...` markdown links emitted by
    /// ``BibleReferenceLinkifier`` and routes them through
    /// ``BibleDeepLinkRouter``. Apply at the chat transcript root —
    /// non-Bible URLs fall through to the default system action so
    /// `https://` links still open in Safari.
    func bibleDeepLinkRouting(eventBus: SuperEventBus?) -> some View {
        environment(\.openURL, OpenURLAction { url in
            if BibleDeepLinkRouter.handle(url: url, eventBus: eventBus) {
                return .handled
            }
            return .systemAction
        })
    }
}
