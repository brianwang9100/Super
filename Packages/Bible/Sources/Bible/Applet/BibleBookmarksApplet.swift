import Core
import GRDBQuery
import SwiftUI

/// The Bookmarks mini-applet — a second `MiniApplet` in the Bible package,
/// SuperBible-only. It lists the six fixed bookmark slots and navigates the
/// reader when an assigned row is tapped.
///
/// It lives in the Bible package (not Core) because its screen reads
/// `bible.sqlite` through a GRDBQuery `@Query`; a separate package for one
/// screen would be overkill. It is constructed via
/// `BibleApplet.makeBookmarksApplet()`, which hands over the same read-only
/// `DatabaseContext` the reader uses — so the Bible-internal `BibleDatabase`
/// never leaks into the composition root (mirrors `makeBulkAnnotationWiring`).
///
/// The applet is deliberately mute toward the LLM: an empty `systemPrompt`
/// (the registry drops empty bodies) and the default empty `suggestedChatActions`.
/// Bookmark navigation is a pure UI affordance with no chat surface.
public struct BibleBookmarksApplet: MiniApplet {
    /// Stable, lowercase identifier — used for routing and the sidebar rail.
    public static let appletID: String = "bookmarks"
    public var appletID: String { Self.appletID }
    public var displayName: String { "Bookmarks" }

    /// Muted gold, drawn from the bookmark palette's `gold` slot so the rail
    /// glyph sits in the feature's own colour family while staying distinct
    /// from Bible's plum and Chats' sage.
    public static let accentColor: Color = Color(red: 0.62, green: 0.50, blue: 0.24)
    public var accentColor: Color { Self.accentColor }

    /// Empty — the applet exposes no behavior to the LLM. The registry skips
    /// empty bodies, so no briefing block is injected.
    public var systemPrompt: String { "" }

    /// Read-only database access for the screen's `@Query<AllBookmarksRequest>`,
    /// injected into the SwiftUI environment by `rootView()`. `nil` when the
    /// database failed to open — the list then renders all-empty slots rather
    /// than failing outright.
    private let databaseContext: DatabaseContext?

    init(databaseContext: DatabaseContext?) {
        self.databaseContext = databaseContext
    }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(BookmarksAppletIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        let screen = BookmarksScreen()
        guard let databaseContext else { return AnyView(screen) }
        return AnyView(screen.databaseContext(databaseContext))
    }
}
