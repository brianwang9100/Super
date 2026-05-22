import Chat
import Core
import SwiftUI

/// Shell-level placeholder applets — visual stubs that register with the
/// `AppletRegistry` so the sidebar can switch between them and the chat
/// overlay has something to render behind it. Each owns no data and only
/// renders a centered icon + name through `AppletPlaceholderScreen`.
/// Real applets ship as their own Swift Package (see `Packages/Bible/` for
/// the pattern) and replace their stub here as they land.
///
/// Accent colors per `docs/DESIGN.md §8.2`: muted OKLCH-shifted derivatives
/// of the pastel-green palette, not raw bright colors. Approximated here
/// with hand-picked SwiftUI `Color` values that read in the same hue/satur-
/// ation neighborhood across all three themes.

// MARK: - Recipes

struct RecipesPlaceholderApplet: MiniApplet {
    static let appletID: String = "recipes"
    var appletID: String { Self.appletID }
    var displayName: String { "Recipes" }
    var accentColor: Color { Color(red: 0.74, green: 0.55, blue: 0.28) }   // warm ochre
    /// Placeholder — no behavioral guidance authored yet. The registry
    /// skips empty bodies, so the leading system message gets no Recipes
    /// block until this stub is replaced by a real package with a
    /// `Resources/SystemPrompt.md`.
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

// MARK: - Finance

struct FinancePlaceholderApplet: MiniApplet {
    static let appletID: String = "finance"
    var appletID: String { Self.appletID }
    var displayName: String { "Finance" }
    var accentColor: Color { Color(red: 0.20, green: 0.50, blue: 0.52) }   // deep teal
    /// Placeholder — no behavioral guidance authored yet (see Recipes).
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
