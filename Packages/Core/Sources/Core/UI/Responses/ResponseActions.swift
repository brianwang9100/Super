import SwiftUI

public struct ResponseActions: View {
    private let onCopy: () -> Void
    private let onRegenerate: () -> Void
    private let isRegenerateDisabled: Bool

    /// The host owns pasteboard feedback and any regeneration confirmation.
    public init(
        onCopy: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        isRegenerateDisabled: Bool = false
    ) {
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.isRegenerateDisabled = isRegenerateDisabled
    }

    public var body: some View {
        HStack(spacing: 4) {
            MessageActionButton(systemName: "doc.on.doc", label: "Copy", action: onCopy)
            MessageActionButton(systemName: "arrow.clockwise", label: "Regenerate", action: onRegenerate, disabled: isRegenerateDisabled)
        }
    }
}
