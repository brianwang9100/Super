import Core
import SwiftUI

/// Shared chrome for the Bible reader's two bottom-anchored cards
/// (``BibleActionSheet`` and ``NarrationTransportSheet``): the drag handle, the
/// drag-to-dismiss gesture, the unified rounded background + border + shadow,
/// the card's content padding, and the live drag offset.
///
/// This is the single source of truth for the carefully-tuned drag behaviour.
/// The `.global` gesture coordinate space and the `.animation(nil, value:)`
/// offset suppression are load-bearing anti-jitter fixes — see the inline
/// comments — and must not be altered when reused.
///
/// A drag past `dismissTranslationThreshold` (or a fast downward flick past
/// `dismissPredictedThreshold`) calls `onDismiss`, which callers wrap in
/// `withAnimation` so the card rides out on the screen's `BibleSheetMotion`.
/// Anything shorter springs back to centre. Per-card layout differences (the
/// content insets, the handle-to-content gap, and the outer horizontal margin)
/// live in ``BibleSheetChromeStyle``; the corner radius, border, and shadow are
/// fixed so both cards read as the same surface.
struct BibleSheetChromeModifier: ViewModifier {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live drag offset for the handle gesture. Reset to zero on a short drag
    /// (spring-back); on a drag past the dismiss threshold the offset is left
    /// at its end position so the card's slide-out transition continues from
    /// where the finger left it instead of snapping back to centre first.
    @State private var dragOffset: CGFloat = 0

    let style: BibleSheetChromeStyle
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        VStack(spacing: style.handleToContentSpacing) {
            dragHandle
            content
        }
        .padding(.horizontal, style.contentHorizontalPadding)
        .padding(.top, style.contentTopPadding)
        .padding(.bottom, style.contentBottomPadding)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(theme.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(theme.borderFaint, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 6)
        .offset(y: dragOffset)
        // Suppresses SwiftUI's implicit transaction animation on gesture-driven
        // offset changes. Without this, the parent `withAnimation` contexts the
        // screen wraps around presentation flips leak into the per-frame offset
        // updates and read as a visible jitter while dragging.
        .animation(nil, value: dragOffset)
        .padding(.horizontal, style.outerHorizontalPadding)
    }

    /// Corner radius shared by both cards. Continuous-style so the two bottom
    /// surfaces read identically.
    private static let cornerRadius: CGFloat = 24

    // MARK: Drag handle

    /// Horizontal pill at the top of the card that the user grabs to dismiss.
    /// The visible capsule is small; the surrounding container is intentionally
    /// taller (and uses `contentShape(Rectangle())`) so the touch target
    /// matches a system sheet's drag affordance rather than just the 4pt pill.
    /// A drag past `dismissTranslationThreshold` (or with enough downward
    /// flick velocity) calls `onDismiss`; anything shorter springs back to
    /// centre.
    private var dragHandle: some View {
        Capsule()
            .fill(theme.inkFaint)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
            // `.global` (not `.local`) is load-bearing: the offset modifier
            // moves the handle's local origin every frame, so a `.local`-space
            // gesture would measure each `onChanged` value against a moved
            // coordinate system and produce a self-feedback jitter. Global space
            // keeps the gesture coordinate stable while the card follows the
            // finger.
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        // Upward drags clamp to zero so the card doesn't peel
                        // off the top — only downward motion counts toward
                        // dismissal.
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        let dragged = value.translation.height
                        let predicted = value.predictedEndTranslation.height
                        if dragged > Self.dismissTranslationThreshold ||
                           predicted > Self.dismissPredictedThreshold {
                            // Leave dragOffset where the finger left it so the
                            // slide-out transition continues from the same
                            // position instead of snapping back to centre first.
                            // The caller wraps `onDismiss` in `withAnimation`, so
                            // the card rides out on the screen's sheet motion.
                            onDismiss()
                        } else {
                            let springBack: Animation? = reduceMotion
                                ? nil
                                : .spring(response: 0.32, dampingFraction: 0.85)
                            withAnimation(springBack) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    /// Downward drag distance past which the card commits to dismiss.
    private static let dismissTranslationThreshold: CGFloat = 80
    /// Predicted end translation past which a quick flick (even with small
    /// current displacement) commits to dismiss — mirrors how system sheets
    /// honour velocity.
    private static let dismissPredictedThreshold: CGFloat = 160
}
