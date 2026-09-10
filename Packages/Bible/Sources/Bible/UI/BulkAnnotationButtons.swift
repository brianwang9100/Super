import Core
import SwiftUI

// Keep Generate/Delete semantic fills solid; glass frosting would dilute their accent/danger meaning.

struct BulkRoundIconButton: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let systemName: String
    let size: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    init(
        systemName: String,
        size: CGFloat = 32,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(typography.font(size: size * 0.46, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .superGlassButton(in: Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct BulkPrimaryButton: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let title: String
    let systemImage: String?
    let action: () -> Void

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(typography.font(size: 16, weight: .semibold))
                }
                Text(title).font(typography.font(.callout, weight: .semibold))
            }
            .foregroundStyle(theme.accentInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.accent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct BulkDangerButton: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let title: String
    let systemImage: String?
    let action: () -> Void

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(typography.font(size: 15, weight: .semibold))
                }
                Text(title).font(typography.font(.callout, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.errorAccent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct BulkRetryButton: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let title: String
    let action: () -> Void

    init(title: String = "Retry", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise").font(typography.font(size: 12, weight: .semibold))
                Text(title).font(typography.font(.caption, weight: .semibold))
            }
            .foregroundStyle(theme.errorInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.errorBackground))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
