import Core
import SwiftUI

/// The "Annotate selection" trigger that lives at the trailing edge of
/// the chapter nav bar.
///
/// Two states distinguish "no selection" from "verses selected":
///
/// - `.dim` — raised pill on `backgroundRaised`, faint `inkMute` glyph,
///   `0.6` opacity. Visually inert; tap is disabled.
/// - `.active` — accent-filled pill with white sparkle and a soft tinted
///   shadow. Tapping fires `bible.annotate` against the current selection.
///
/// The sparkle glyph reuses SF Symbol `sparkles` to stay aligned with the
/// nav bar's existing spark icon usage (`BibleNavBar`'s chat-spark menu)
/// — one glyph family per applet.
struct SparkButton: View {
    @Environment(\.superTheme) private var theme

    /// Named `ButtonState` rather than `State` to avoid shadowing
    /// `SwiftUI.State` within this struct's scope — the same naming
    /// rationale `AnnotationBlock.Content` follows to avoid clashing
    /// with `View.body`.
    enum ButtonState: Sendable, Equatable {
        case dim
        case active
    }

    let state: ButtonState
    let action: () -> Void

    init(state: ButtonState, action: @escaping () -> Void) {
        self.state = state
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(state == .active ? theme.accentInk : theme.inkMute)
                .frame(width: 36, height: 36)
                .background(background)
                .overlay(border)
                .opacity(state == .active ? 1 : 0.6)
                .shadow(
                    color: state == .active
                        ? theme.accent.opacity(0.3)
                        : .black.opacity(0.05),
                    radius: state == .active ? 5 : 1,
                    y: state == .active ? 3 : 1
                )
        }
        .buttonStyle(.plain)
        .disabled(state == .dim)
        .accessibilityLabel("Annotate selection")
    }

    private var background: some View {
        Circle()
            .fill(state == .active ? theme.accent : theme.backgroundRaised)
    }

    @ViewBuilder
    private var border: some View {
        if state == .dim {
            Circle().strokeBorder(theme.borderFaint, lineWidth: 0.5)
        }
    }
}
