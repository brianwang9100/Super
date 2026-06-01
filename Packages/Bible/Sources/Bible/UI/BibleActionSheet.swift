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
    /// Invoked when the "Annotate" tile is tapped — routes the selection
    /// through the view-model's disclaimer-gated generation flow.
    let onAnnotate: () -> Void
    /// Invoked when the "Add note" tile is tapped — composes a user note on
    /// the selection's bounding range through the view model.
    let onAddNote: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            highlightRow
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
                .padding(.horizontal, 2)
            actionRow
        }
        .modifier(BibleSheetChromeModifier(style: .actionSheet, onDismiss: onClose))
    }

    private var header: some View {
        HStack {
            Text(citation)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
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
            actionButton(label: "Annotate", accent: true, action: onAnnotate) {
                AnnotationBubble(state: .filled, size: 18)
            }
            actionButton(label: "Add note", accent: true, action: onAddNote) {
                NoteGlyph(state: .filled, size: 18)
            }
            actionButton(label: "Add to chat", accent: true, action: onAddToChat) {
                sfIcon("paperplane.fill", accent: true)
            }
            actionButton(label: "New chat", accent: true, action: onNewChat) {
                sfIcon("bubble.left.and.bubble.right.fill", accent: true)
            }
            actionButton(label: "Copy", accent: false, action: onCopy) {
                sfIcon("doc.on.doc", accent: false)
            }
            ShareLink(item: shareText) {
                actionTile(label: "Share", accent: false) {
                    sfIcon("square.and.arrow.up", accent: false)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private func sfIcon(_ symbol: String, accent: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(accent ? theme.accent : theme.ink)
    }

    private func actionButton<Icon: View>(
        label: String,
        accent: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            actionTile(label: label, accent: accent, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func actionTile<Icon: View>(
        label: String,
        accent: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 6) {
            icon()
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
