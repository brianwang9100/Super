import Chat
import Core
import SwiftUI

/// M2 placeholder applets — four shell-level stubs that register with the
/// `AppletRegistry` so the sidebar can switch between them and M3's chat
/// overlay has something to render behind it. None of these own data or
/// conform to additional protocols (tools, chat cards, event subscriptions);
/// they're pure visual entry points until each gets a real implementation.
///
/// Accent colors per `docs/DESIGN.md §8.2`: muted OKLCH-shifted derivatives
/// of the pastel-green palette, not raw bright colors. Approximated here
/// with hand-picked SwiftUI `Color` values that read in the same hue/satur-
/// ation neighborhood across all three themes.

// MARK: - Todo

struct ToDoPlaceholderApplet: MiniApplet {
    static let appletID: String = "todo"
    var appletID: String { Self.appletID }
    var displayName: String { "Todo" }
    var accentColor: Color { Color(red: 0.30, green: 0.45, blue: 0.78) }   // cobalt

    @MainActor
    func iconView(size: CGFloat) -> AnyView {
        AnyView(TodoIcon(size: size))
    }

    @MainActor
    func rootView() -> AnyView {
        AnyView(AppletPlaceholderScreen(
            displayName: "Todo",
            accent: accentColor,
            icon: { TodoIcon(size: 44) }
        ))
    }
}

// MARK: - Recipes

struct RecipesPlaceholderApplet: MiniApplet {
    static let appletID: String = "recipes"
    var appletID: String { Self.appletID }
    var displayName: String { "Recipes" }
    var accentColor: Color { Color(red: 0.74, green: 0.55, blue: 0.28) }   // warm ochre

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

// MARK: - Bible

struct BiblePlaceholderApplet: MiniApplet {
    static let appletID: String = "bible"
    var appletID: String { Self.appletID }
    var displayName: String { "Bible" }
    var accentColor: Color { Color(red: 0.52, green: 0.32, blue: 0.55) }   // plum

    @MainActor
    func iconView(size: CGFloat) -> AnyView {
        AnyView(BibleIcon(size: size))
    }

    @MainActor
    func rootView() -> AnyView {
        AnyView(AppletPlaceholderScreen(
            displayName: "Bible",
            accent: accentColor,
            icon: { BibleIcon(size: 44) }
        ))
    }
}

// MARK: - Finance

struct FinancePlaceholderApplet: MiniApplet {
    static let appletID: String = "finance"
    var appletID: String { Self.appletID }
    var displayName: String { "Finance" }
    var accentColor: Color { Color(red: 0.20, green: 0.50, blue: 0.52) }   // deep teal

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
