import Core
import GRDBQuery
import SwiftUI

/// Construct through BibleApplet.makeBookmarksApplet() to share the reader's database context.
public struct BibleBookmarksApplet: MiniApplet {
    public static let appletID: String = "bookmarks"
    public var appletID: String { Self.appletID }
    public var displayName: String { "Bookmarks" }

    public static let accentColor: Color = Color(red: 0.62, green: 0.50, blue: 0.24)
    public var accentColor: Color { Self.accentColor }

    /// UI-only navigation needs no LLM briefing; the registry skips empty bodies.
    public var systemPrompt: String { "" }

    // Nil storage renders empty bookmark slots.
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
