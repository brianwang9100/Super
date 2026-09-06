/// A selection displayed between the composer's accessory buttons. The applet
/// supplies its label and actions; the composer owns placement and disclosure.
public struct ComposerAccessorySelection {
    public let title: String
    public let accessibilityLabel: String
    public let isExpanded: Bool
    public let onExpand: () -> Void
    public let onClear: () -> Void

    public init(
        title: String,
        accessibilityLabel: String,
        isExpanded: Bool,
        onExpand: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.isExpanded = isExpanded
        self.onExpand = onExpand
        self.onClear = onClear
    }
}
