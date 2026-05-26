import SwiftUI

/// Catalog of design-system icons mirroring `ds/ds-icons.jsx`. Each case
/// maps to an `.imageset` of the same raw value inside `Icons.xcassets` in
/// Chat's resource bundle. Use via `Image(dsIcon:)`; the asset ships as a
/// template image, so tint with `.foregroundStyle(...)` at the call site.
public enum DSIcon: String, CaseIterable, Sendable {
    case menu = "Menu"
    case plus = "Plus"
    case close = "Close"
    case mic = "Mic"
    case chevronDown = "ChevronDown"
    case chevronRight = "ChevronRight"
    case chevronUp = "ChevronUp"
    case settings = "Settings"
    case check = "Check"
    case copy = "Copy"
    case refresh = "Refresh"
    case stop = "Stop"
    case arrowUp = "ArrowUp"
    case spark = "Spark"
    case todo = "Todo"
    case recipe = "Recipe"
    case bible = "Bible"
    case finance = "Finance"
    case newChat = "NewChat"
    case think = "Think"
    case tool = "Tool"
    case edit = "Edit"
    case trash = "Trash"
    case star = "Star"
    case highlight = "Highlight"
    case tag = "Tag"
    case send = "Send"
    case open = "Open"
    case search = "Search"
    case sun = "Sun"
    case moon = "Moon"
    case bell = "Bell"
}

extension DSIcon {
    /// The resource bundle that ships the icon assets. Exposed for test
    /// code that needs to do a synchronous asset-presence assertion
    /// outside the `Image(dsIcon:)` path — `Bundle.module` resolves to
    /// the *defining* module, so a test target's `Bundle.module` is its
    /// own bundle, not Chat's.
    public static var resourceBundle: Bundle { Bundle.module }
}

extension Image {
    /// Loads a design-system icon from Chat's `Icons.xcassets`. The asset is
    /// already marked template-rendering, so the loaded image tints with
    /// `.foregroundStyle(...)` at the call site.
    public init(dsIcon: DSIcon) {
        self.init(dsIcon.rawValue, bundle: DSIcon.resourceBundle)
    }
}
