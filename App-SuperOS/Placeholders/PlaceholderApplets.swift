import Chat
import Core
import SwiftUI

struct RecipesPlaceholderApplet: MiniApplet {
    static let appletID: String = "recipes"
    var appletID: String { Self.appletID }
    var displayName: String { "Recipes" }
    var accentColor: Color { Color(red: 0.74, green: 0.55, blue: 0.28) }   // warm ochre
    /// Empty prompts exclude placeholders from the model's applet briefings.
    var systemPrompt: String { "" }

    @MainActor
    func iconView(size: CGFloat) -> AnyView {
        AnyView(RecipeIcon(size: size))
    }

    @MainActor
    func rootView() -> AnyView {
        AnyView(AppletPlaceholderScreen(
            displayName: "Recipes",
            accent: accentColor,
            icon: { RecipeIcon(size: 44) }
        ))
    }
}

struct FinancePlaceholderApplet: MiniApplet {
    static let appletID: String = "finance"
    var appletID: String { Self.appletID }
    var displayName: String { "Finance" }
    var accentColor: Color { Color(red: 0.20, green: 0.50, blue: 0.52) }   // deep teal
    var systemPrompt: String { "" }

    @MainActor
    func iconView(size: CGFloat) -> AnyView {
        AnyView(FinanceIcon(size: size))
    }

    @MainActor
    func rootView() -> AnyView {
        AnyView(AppletPlaceholderScreen(
            displayName: "Finance",
            accent: accentColor,
            icon: { FinanceIcon(size: 44) }
        ))
    }
}
