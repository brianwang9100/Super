import SwiftUI

public struct VerseReferencePillModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

struct VerseReferencePill: View {
    let label: String
    let onRemove: (() -> Void)?

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// System faces need ScaledMetric to combine Dynamic Type with app font scaling.
    @ScaledMetric(relativeTo: .caption) private var basePoint: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "book.closed.fill")
                .font(typography.font(size: basePoint * 0.85))
            Text(label)
                .font(typography.font(size: basePoint, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(typography.font(size: basePoint * 0.8, weight: .bold))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label)")
            }
        }
        .foregroundStyle(theme.accent)
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 5)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.accentSoft))
        // Keep the remove button independently focusable.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bible reference, \(label)")
    }
}
