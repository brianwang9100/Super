import Core
import SwiftUI

struct SettingsHeader: View {
    let title: String
    let isRoot: Bool
    let onBack: () -> Void
    let onClose: () -> Void
    var trailingAction: (() -> Void)?
    var trailingAccessibilityLabel: String?

    init(
        title: String,
        isRoot: Bool,
        onBack: @escaping () -> Void,
        onClose: @escaping () -> Void,
        trailingAction: (() -> Void)? = nil,
        trailingAccessibilityLabel: String? = nil
    ) {
        self.title = title
        self.isRoot = isRoot
        self.onBack = onBack
        self.onClose = onClose
        self.trailingAction = trailingAction
        self.trailingAccessibilityLabel = trailingAccessibilityLabel
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        HStack(spacing: 0) {
            iconButton(action: isRoot ? onClose : onBack) {
                if isRoot {
                    CloseIcon(size: 16)
                        .foregroundStyle(theme.ink)
                } else {
                    BackChevronIcon(size: 18)
                        .foregroundStyle(theme.ink)
                }
            }
            .accessibilityLabel(isRoot ? "Close settings" : "Back")

            Text(title)
                .font(typography.font(.body, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            if let trailingAction {
                iconButton(action: trailingAction, prominent: true, haptic: .primary) {
                    PlusIcon(size: 18)
                        .foregroundStyle(theme.accentInk)
                }
                .accessibilityLabel(trailingAccessibilityLabel ?? "Add")
            } else {
                // Balance the leading control when there is no trailing action.
                iconButton(action: {}) {
                    CloseIcon(size: 16)
                }
                .hidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 1)
        }
    }

    /// Dismissal chrome stays silent; only the prominent add action requests a haptic.
    @ViewBuilder
    private func iconButton<Content: View>(
        action: @escaping () -> Void,
        prominent: Bool = false,
        haptic: HapticPattern? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            iconGlass(content().frame(width: 44, height: 44), prominent: prominent)
        }
        .buttonStyle(GlassHapticButtonStyle(haptic))
    }

    @ViewBuilder
    private func iconGlass(_ content: some View, prominent: Bool) -> some View {
        if prominent {
            content.superGlassCTAButton(in: Circle())
        } else {
            content.superGlassButton(in: Circle())
        }
    }
}
