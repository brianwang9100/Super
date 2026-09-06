import SwiftUI

/// A selection label with independent actions to reopen its controls or clear
/// the selection. An optional disclosure symbol points toward those controls.
public struct SelectionPill: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private let title: String
    private let accessibilityLabel: String
    private let onAction: () -> Void
    private let onClear: () -> Void
    private let disclosureSystemImage: String?
    private let morph: GlassMorphID?

    public init(
        title: String,
        accessibilityLabel: String,
        onAction: @escaping () -> Void,
        onClear: @escaping () -> Void,
        disclosureSystemImage: String? = nil,
        morph: GlassMorphID? = nil
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.onAction = onAction
        self.onClear = onClear
        self.disclosureSystemImage = disclosureSystemImage
        self.morph = morph
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: onAction) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(typography.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let disclosureSystemImage {
                        Image(systemName: disclosureSystemImage)
                            .font(typography.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.inkSoft)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassHapticButtonStyle(.selection))
            .accessibilityLabel(accessibilityLabel)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(typography.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.inkSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selection")
        }
        .padding(.trailing, 6)
        .frame(height: 44)
        .superGlassSurface(in: Capsule(), morph: morph)
    }
}
