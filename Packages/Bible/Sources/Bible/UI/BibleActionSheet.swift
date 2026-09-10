import Core
import SwiftUI

struct BibleActionSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private let sizing = SheetSizing.fitsContent

    let citation: String
    let shareText: String
    let onHighlight: (BibleHighlightColor) -> Void
    let onClearHighlight: () -> Void
    let onCopy: () -> Void
    let onNarrate: (() -> Void)?
    let onAddToChat: () -> Void
    let onNewChat: () -> Void
    let onAnnotate: () -> Void
    let onAddNote: () -> Void
    /// Dismisses actions while preserving the reader's selection.
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Keep the nav bar outside content padding to avoid doubling its own inset.
            SheetNavBar(title: citation, sizing: sizing, onClose: onClose)
            VStack(spacing: 0) {
                highlightRow
                divider
                actionRows
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 10)
        // Share estimated height with the reader's bottom scroll reserve.
        .sheetPresentation(
            sizing,
            readableBackground: true,
            estimatedHeight: BibleBottomOverlayKind.selection.estimatedSheetHeight
        )
    }

    private var highlightRow: some View {
        HStack(spacing: 8) {
            Text("HIGHLIGHT")
                .font(typography.font(size: 9.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(theme.inkFaint)
            Spacer()
            ForEach(BibleHighlightColor.allCases) { color in
                Button { onHighlight(color) } label: {
                    Color.clear
                        .frame(width: 28, height: 28)
                        .superGlassButton(in: Circle(), tint: color.swatch.color, interactive: false)
                }
                .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
                .accessibilityLabel("Highlight \(color.displayName.lowercased())")
            }
            Button(action: onClearHighlight) {
                Image(systemName: "xmark")
                    .font(typography.font(size: 11, weight: .bold))
                    .foregroundStyle(theme.inkFaint)
                    .frame(width: 28, height: 28)
                    .superGlassButton(in: Circle(), interactive: false)
            }
            .buttonStyle(GlassHapticButtonStyle(.deselection, scale: true))
            .accessibilityLabel("Clear highlight")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.borderFaint)
            .frame(height: 1)
            .padding(.horizontal, 2)
    }

    private var actionRows: some View {
        VStack(spacing: 0) {
            aiActionRow
                .padding(.bottom, 6)
            divider
            plainTextActionRow
                .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    private var aiActionRow: some View {
        HStack(spacing: 4) {
            actionButton(label: "Annotate", accent: true, action: onAnnotate) {
                AnnotationBubble(state: .filled, size: 22)
            }
            actionButton(label: "Add note", accent: true, action: onAddNote) {
                NoteGlyph(state: .filled, size: 22)
            }
            actionButton(label: "Add to chat", accent: true, action: onAddToChat) {
                sfIcon("paperplane.fill", accent: true)
            }
            actionButton(label: "New chat", accent: true, action: onNewChat) {
                sfIcon("bubble.left.and.bubble.right.fill", accent: true)
            }
        }
    }

    private var plainTextActionRow: some View {
        HStack(spacing: 4) {
            actionButton(label: "Copy", accent: false, action: onCopy) {
                sfIcon("doc.on.doc", accent: false)
            }
            actionTile(label: "Share", accent: false) {
                ShareLink(item: shareText) {
                    tileGlassLabel(tint: nil) { sfIcon("square.and.arrow.up", accent: false) }
                }
                .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
                .accessibilityLabel("Share")
            }
            if let onNarrate {
                actionButton(label: "Narrate", accent: false, action: onNarrate) {
                    sfIcon("speaker.wave.2", accent: false)
                }
            } else {
                actionPlaceholderTile
            }
            // Hidden real tiles preserve column width and height; flexible spacers can stretch the sheet.
            actionPlaceholderTile
        }
    }

    private var actionPlaceholderTile: some View {
        actionTile(label: " ", accent: false) {
            tileGlassLabel(tint: nil) { Color.clear.frame(width: 22, height: 22) }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func sfIcon(_ symbol: String, accent: Bool) -> some View {
        Image(systemName: symbol)
            .font(typography.font(size: 20, weight: .medium))
            .foregroundStyle(accent ? theme.accent : theme.ink)
    }

    // Scale only the glass control, leaving its caption stationary.
    private func actionButton<Icon: View>(
        label: String,
        accent: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        actionTile(label: label, accent: accent) {
            Button(action: action) {
                tileGlassLabel(tint: accent ? theme.accentSoft : nil, icon: icon)
            }
            .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
            .accessibilityLabel(label)
        }
    }

    private func tileGlassLabel<Icon: View>(
        tint: Color?,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        icon()
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .superGlassButton(in: RoundedRectangle(cornerRadius: 16), tint: tint, interactive: false)
    }

    private func actionTile<Control: View>(
        label: String,
        accent: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 8) {
            control()
            // The control already owns this accessibility label; hide the decorative duplicate.
            Text(label)
                .font(typography.font(size: 11, weight: .medium))
                .foregroundStyle(accent ? theme.accent : theme.ink)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
    }
}
