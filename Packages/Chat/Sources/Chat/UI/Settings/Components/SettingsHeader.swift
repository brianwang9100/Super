import Core
import SwiftUI

/// Top bar of the Settings sheet: leading 44pt circular Liquid Glass button
/// (back chevron on sub-panes, close X on the root pane), centered semibold
/// title, and a trailing 44pt slot. The slot carries an optional Liquid Glass
/// action button (e.g. the Models pane's "add model" plus) when
/// `trailingAction` is set; otherwise it's a hidden spacer that keeps the
/// title visually centered.
struct SettingsHeader: View {
    let title: String
    let isRoot: Bool
    let onBack: () -> Void
    let onClose: () -> Void
    /// Optional trailing glass button action. `nil` ⇒ the trailing slot is a
    /// hidden spacer (the default for panes without a top-bar action). When
    /// present it renders as an accent-tinted call-to-action button (the
    /// add-model **+**), distinct from the neutral leading close/back glass.
    var trailingAction: (() -> Void)?
    /// VoiceOver label for the trailing button when `trailingAction` is set.
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
                iconButton(action: trailingAction, prominent: true) {
                    PlusIcon(size: 18)
                        .foregroundStyle(theme.accentInk)
                }
                .accessibilityLabel(trailingAccessibilityLabel ?? "Add")
            } else {
                // Hidden spacer mirrors the React `visibility: hidden` button
                // on the trailing edge so the title stays centered to the
                // chrome when there's no top-bar action.
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

    /// - Parameter prominent: When `true`, the button rides accent-tinted
    ///   call-to-action glass (the trailing add **+**); otherwise neutral nav
    ///   glass (the leading close/back).
    @ViewBuilder
    private func iconButton<Content: View>(
        action: @escaping () -> Void,
        prominent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            iconGlass(content().frame(width: 44, height: 44), prominent: prominent)
        }
        .buttonStyle(.plain)
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
