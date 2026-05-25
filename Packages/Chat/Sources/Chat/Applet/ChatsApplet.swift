import Core
import GRDBQuery
import SwiftUI

/// `MiniApplet` conformance for the Chats backdrop — a searchable
/// full-screen list of every active conversation. Distinct from the
/// Chat overlay (which floats *above* every backdrop applet); when
/// the user selects Chats from the sidebar rail the chat overlay
/// collapses to its minimized dock so this list owns the screen.
///
/// Reads the conversation table reactively via GRDBQuery — the
/// screen's `@Query(ActiveConversationsRequest())` re-renders on any
/// write (new chat created from the overlay, title generated, message
/// sent bumping `updatedAt`) without manual refresh wiring. Tapping a
/// row publishes `.openConversationRequested(id:)` on the shared
/// event bus; the green "+" publishes `.newConversationRequested`.
/// The shell drains both and routes to its existing
/// `selectConversation(id:)` / `startNewChat()` paths.
public struct ChatsApplet: MiniApplet {
    /// Stable identifier referenced by the sidebar, deep-link router,
    /// and `AppletRegistry.activeID`.
    public static let appletID: String = "chats"

    /// Muted sage green — distinct from Chat's primary accent (the
    /// bright pastel green of the chat overlay) and from every other
    /// registered applet so the sidebar rail rows stay visually
    /// separable. Per `docs/DESIGN.md §8.2` accent colors should be
    /// muted OKLCH-shifted derivatives, not raw bright values.
    public static let accentColor: Color = Color(red: 0.36, green: 0.55, blue: 0.42)

    private let chatDatabase: ChatDatabase

    /// - Parameter chatDatabase: The same `ChatDatabase` instance the
    ///   composition root hands the rest of Chat. Threaded through so
    ///   `ChatsScreen`'s `@Query` observes the live `conversation`
    ///   table rather than an isolated copy.
    public init(chatDatabase: ChatDatabase) {
        self.chatDatabase = chatDatabase
    }

    public var appletID: String { Self.appletID }

    public var displayName: String { "Chats" }

    public var accentColor: Color { Self.accentColor }

    /// Empty — the Chats applet exposes no behavior to the LLM (the
    /// model already knows how to talk about its own chat history
    /// through the existing Chat system prompt). The registry skips
    /// empty bodies, so no `## Chats applet` block is injected.
    public var systemPrompt: String { "" }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(ChatsIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        AnyView(
            ChatsScreen()
                // Read-only: the screen never writes to the
                // conversation table. New-chat + open-chat dispatch
                // through the event bus so the shell's existing
                // lazy-persist driver remains the single writer.
                .databaseContext(.readOnly { chatDatabase.queue })
        )
    }
}
