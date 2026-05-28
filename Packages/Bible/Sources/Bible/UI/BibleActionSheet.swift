import Core
import SwiftUI

/// The bottom sheet shown while verses are selected: the passage citation, a
/// highlight-colour row, and the Copy / Share / chat actions.
///
/// The highlight row, Copy, and Share are all live: a swatch paints the
/// selected verses, the dashed circle clears them. The two chat actions stand
/// in for the deferred hand-off and raise a "coming soon" toast.
struct BibleActionSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live drag offset for the handle gesture. Reset to zero on a short drag
    /// (spring-back); on a drag past the dismiss threshold the offset is left
    /// at its end position so the card's slide-out transition continues from
    /// where the finger left it instead of snapping back to centre first.
    @State private var dragOffset: CGFloat = 0

    /// The selection citation shown in the sheet header, e.g. `"1 Peter 2:9"`.
    let citation: String
    /// The verse text + citation handed to the system share sheet.
    let shareText: String
    /// Invoked with the chosen colour when a highlight swatch is tapped.
    let onHighlight: (BibleHighlightColor) -> Void
    /// Invoked when the dashed "clear" circle is tapped.
    let onClearHighlight: () -> Void
    let onCopy: () -> Void
    let onAddToChat: () -> Void
    let onNewChat: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            highlightRow
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
                .padding(.horizontal, 2)
            actionRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 20).fill(theme.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.borderFaint, lineWidth: 0.5))
        .offset(y: dragOffset)
        // Suppresses SwiftUI's implicit transaction animation on gesture-driven
        // offset changes. Without this, the parent `withAnimation` contexts the
        // screen wraps around presentation flips leak into the per-frame offset
        // updates and read as a visible jitter while dragging.
        .animation(nil, value: dragOffset)
        .padding(.horizontal, 8)
    }

    // MARK: Drag handle

    /// Horizontal pill at the top of the card that the user grabs to dismiss.
    /// The visible capsule is small; the surrounding container is intentionally
    /// taller (and uses `contentShape(Rectangle())`) so the touch target
    /// matches a system sheet's drag affordance rather than just the 4pt pill.
    /// Mirrors `NarrationTransportSheet`'s handle so the two bottom cards drag
    /// identically. A drag past ``Self.dismissTranslationThreshold`` (or with
    /// enough downward flick velocity) calls `onClose`; anything shorter springs
    /// back to centre.
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
                            // `onClose` wraps `clearSelection()` in
                            // `withAnimation`, so the card rides out on the
                            // screen's sheet motion.
                            onClose()
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

    private var header: some View {
        HStack {
            Text(citation)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkFaint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private var highlightRow: some View {
        HStack(spacing: 8) {
            Text("HIGHLIGHT")
                .font(.system(size: 9.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(theme.inkFaint)
            Spacer()
            ForEach(BibleHighlightColor.allCases) { color in
                Button { onHighlight(color) } label: {
                    Circle()
                        .fill(color.swatch.color)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(theme.borderFaint, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Highlight \(color.displayName.lowercased())")
            }
            Button(action: onClearHighlight) {
                Circle()
                    .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 0.5, dash: [2.5]))
                    .background(Circle().fill(theme.backgroundSunken))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.inkFaint)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear highlight")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
    }

    private var actionRow: some View {
        HStack(spacing: 4) {
            actionButton(symbol: "paperplane.fill", label: "Add to chat", accent: true, action: onAddToChat)
            actionButton(symbol: "bubble.left.and.bubble.right.fill", label: "New chat", accent: true, action: onNewChat)
            actionButton(symbol: "doc.on.doc", label: "Copy", accent: false, action: onCopy)
            ShareLink(item: shareText) {
                actionTile(symbol: "square.and.arrow.up", label: "Share", accent: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private func actionButton(
        symbol: String,
        label: String,
        accent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionTile(symbol: symbol, label: label, accent: accent)
        }
        .buttonStyle(.plain)
    }

    private func actionTile(symbol: String, label: String, accent: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(accent ? theme.accent : theme.ink)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent ? theme.accentSoft : theme.backgroundSunken)
                )
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent ? theme.accent : theme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
