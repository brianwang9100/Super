import Core
import GRDBQuery
import SwiftUI

public struct ChatsApplet: MiniApplet {
    public static let appletID: String = "chats"

    public static let accentColor: Color = Color(red: 0.36, green: 0.55, blue: 0.42)

    private let chatDatabase: ChatDatabase

    public init(chatDatabase: ChatDatabase) {
        self.chatDatabase = chatDatabase
    }

    public var appletID: String { Self.appletID }

    public var displayName: String { "Chats" }

    public var accentColor: Color { Self.accentColor }

    public var systemPrompt: String { "" }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(ChatsIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        AnyView(
            ChatsScreen()
                // The shell owns conversation creation; row actions dispatch through the event bus.
                .databaseContext(.readOnly { chatDatabase.queue })
        )
    }
}
