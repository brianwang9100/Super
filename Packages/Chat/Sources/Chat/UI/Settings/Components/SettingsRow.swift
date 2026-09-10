import SwiftUI

struct SettingsRow<Trailing: View>: View {
    let icon: AnyView?
    let label: String
    let value: String?
    let isInteractive: Bool
    let borderBottom: Bool
    let accessibilityHint: String?
    let trailing: Trailing
    let action: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    init(
        icon: AnyView? = nil,
        label: String,
        value: String? = nil,
        isInteractive: Bool = true,
        borderBottom: Bool = true,
        accessibilityHint: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        action: @escaping () -> Void = {}
    ) {
        self.icon = icon
        self.label = label
        self.value = value
        self.isInteractive = isInteractive
        self.borderBottom = borderBottom
        self.accessibilityHint = accessibilityHint
        self.trailing = trailing()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    icon
                        .foregroundStyle(theme.inkSoft)
                        .frame(width: 22, height: 22, alignment: .center)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(typography.font(.callout))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(typography.font(.subheadline))
                        .foregroundStyle(theme.inkFaint)
                }
                trailingView
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if borderBottom {
                    Rectangle()
                        .fill(theme.borderFaint)
                        .frame(height: 1)
                        .padding(.leading, icon == nil ? 18 : 18 + 22 + 14)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .accessibilityLabel(value.map { "\(label), \($0)" } ?? label)
        .accessibilityHint(accessibilityHint ?? "")
    }

    @ViewBuilder
    private var trailingView: some View {
        if Trailing.self == EmptyView.self {
            if isInteractive {
                ForwardChevronIcon()
                    .foregroundStyle(theme.inkFaint)
            }
        } else {
            trailing
        }
    }
}
