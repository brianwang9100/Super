import Core
import SwiftUI

/// Circular task-state indicator: an empty ring for `open`, a filled green
/// disc with a check for `done`, and a muted ring with an ✕ for
/// `cancelled`. Tapping invokes `onToggle`. The box scales with Dynamic
/// Type. Mirrors `StateBox` in the Todo design source's `components.jsx`.
public struct TodoStateBox: View {
    public let state: TaskState
    public let onToggle: () -> Void

    /// Box diameter — 19pt at the default text size, scaled for Dynamic
    /// Type so the control grows alongside the row's text.
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 19
    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    public init(state: TaskState, onToggle: @escaping () -> Void) {
        self.state = state
        self.onToggle = onToggle
    }

    /// Box diameter after both Dynamic Type (`@ScaledMetric`) and the
    /// app-wide font slider are applied.
    private var scaledSize: CGFloat { size * fontScale }

    /// Transparent padding added around the visible ring so the *tappable*
    /// area reaches ~44pt — Apple's recommended minimum. A 19pt control is
    /// far below that, so edge taps missed the button and fell through to
    /// the enclosing row's tap gesture, opening the editor instead of
    /// toggling state. Clamped so a Dynamic-Type-enlarged ring (already at
    /// or past 44pt) never produces negative slop.
    private var hitSlop: CGFloat { max(0, (44 - scaledSize) / 2) }

    public var body: some View {
        Button(action: onToggle) {
            ZStack {
                Circle().fill(state == .done ? Self.doneFill : .clear)
                Circle().strokeBorder(ringColor, lineWidth: 1.5)
                glyph
            }
            .frame(width: scaledSize, height: scaledSize)
            .padding(hitSlop)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Cancel the hit-slop padding from the layout so the row's spacing
        // and the ring's on-screen position are unchanged — only the
        // button's hit-test region grows.
        .padding(-hitSlop)
        .accessibilityLabel(state.displayName)
        .accessibilityHint(state == .open ? "Marks the task done" : "Reopens the task")
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .open:
            EmptyView()
        case .done:
            Image(systemName: "checkmark")
                .font(typography.font(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        case .cancelled:
            Image(systemName: "xmark")
                .font(typography.font(size: size * 0.42, weight: .semibold))
                .foregroundStyle(theme.inkFaint)
        }
    }

    private var ringColor: Color {
        switch state {
        case .open:      theme.inkMute
        case .done:      Self.doneFill
        case .cancelled: theme.borderFaint
        }
    }

    /// Fixed green from the design's `oklch(0.52 0.09 155)` — the "done"
    /// state reads as a positive confirmation independent of the theme.
    private static let doneFill = OKLCH(0.52, 0.09, 155).color
}
