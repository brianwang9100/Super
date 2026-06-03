import Core
import SwiftUI

// Buttons for the bulk-annotation surfaces.
//
// Interactive Liquid Glass goes on the round **icon controls** (back / close /
// pause / cancel) via `superGlassButton`, matching how the rest of the app's
// nav chrome adopts glass — and that helper carries the deterministic solid
// fallback under snapshot tests. The accent **Generate** and red **Delete all**
// buttons stay solid semantic fills: glass would frost away the accent/danger
// colour that *is* their identity, and the only snapshot-safe glass helper is
// the frosting one. So "controls → glass, colour CTAs → solid".

/// A round, glass icon control (32pt) — back / close / pause / cancel.
struct BulkRoundIconButton: View {
    @Environment(\.superTheme) private var theme

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
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .superGlassButton(in: Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Full-width accent primary action — the **Generate** CTA. Solid accent fill
/// (see file note on why this isn't glass).
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
                    Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
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

/// Full-width destructive action — **Delete all annotations**. Solid red.
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
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
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

/// Small soft-tile **Retry** pill in the failure hue — per-row and the
/// failure-banner "Retry all".
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
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
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
