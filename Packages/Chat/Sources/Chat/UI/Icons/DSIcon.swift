import SwiftUI

/// Raw values name template assets in Chat's bundle; tint with foregroundStyle.
enum DSIcon: String, CaseIterable, Sendable {
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
    /// Keep separate from newChat: the shared geometry has a different stroke weight.
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
    /// Exposes Chat's asset bundle to tests, whose own Bundle.module points elsewhere.
    static var resourceBundle: Bundle { Bundle.module }
}

extension Image {
    init(dsIcon: DSIcon) {
        self.init(dsIcon.rawValue, bundle: DSIcon.resourceBundle)
    }
}
