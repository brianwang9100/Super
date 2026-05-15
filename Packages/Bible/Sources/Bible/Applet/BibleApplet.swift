import Core
import SwiftUI

/// The Bible mini-applet entry point. Registered with the shell's
/// `AppletRegistry` at composition root; the shell renders `rootView()`
/// behind the chat overlay.
///
/// M1 loads the bundled World English Bible text and renders 1 Peter 2.
/// The navigation bar, sheets, selection, and persistence land across the
/// remaining milestones.
public struct BibleApplet: MiniApplet {
    /// Stable, lowercase identifier — used for routing, settings keys, and
    /// deep-link URIs (`super://bible/<recordID>`).
    public static let appletID: String = "bible"
    public var appletID: String { Self.appletID }
    public var displayName: String { "Bible" }
    /// Muted plum, matching the prior placeholder so the sidebar glyph and
    /// chat-card accent strips don't shift visually on upgrade.
    public static let accentColor: Color = Color(red: 0.52, green: 0.32, blue: 0.55)
    public var accentColor: Color { Self.accentColor }

    /// The book of 1 Peter, decoded once at composition time. `rootView()`
    /// renders chapter 2 — the demo chapter — until chapter navigation
    /// lands in M2; loading here keeps it off the per-frame render path.
    private let book: BibleBook?

    /// - Parameter textLoader: source of bundled Bible text. Defaults to the
    ///   bundled-resource loader; tests inject a double.
    public init(textLoader: any BibleTextLoader = BundledBibleTextLoader()) {
        self.book = try? textLoader.loadBook(id: "1PE")
    }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(BibleAppletIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        AnyView(BibleScreen(bookName: book?.name ?? displayName, chapter: book?.chapter(2)))
    }
}
