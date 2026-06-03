import Core
import SwiftUI

/// The bottom sheet shown while verses are selected: the passage citation, a
/// highlight-colour row, and two action rows split by a hairline divider — the
/// AI row (Annotate, Add note, Add to chat, New chat) over the plain-text row
/// (Copy, Share).
///
/// Everything here is live: a swatch paints the selected verses, the dashed
/// circle clears them, and each action row tile fires its callback (the chat
/// rows hand the selection off through the event bus).
struct BibleActionSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// Declared once and shared by the nav bar and the presentation so the two
    /// can't drift; a short content-sized card kept over the readable reader.
    private let sizing = SheetSizing.fitsContent

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
    /// Invoked by the nav-bar close button — clears the selection, which
    /// dismisses the sheet.
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The nav bar bakes its own 14pt horizontal inset, so it sits
            // outside the content's 10pt inset rather than doubling it.
            SheetNavBar(title: citation, sizing: sizing, onClose: onClose)
            VStack(spacing: 0) {
                highlightRow
                divider
                actionRows
            }
            .padding(.horizontal, 10)
        }
        // The card is a native `.sheet` (the system supplies the drag bar,
        // rounded surface, and drag-to-dismiss); this is just the bottom inset.
        .padding(.bottom, 10)
        // Sized to content and kept over the still-readable reader.
        .sheetPresentation(sizing, readableBackground: true, estimatedHeight: 280)
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
                            .font(typography.font(size: 11, weight: .bold))
                            .foregroundStyle(theme.inkFaint)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear highlight")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
    }

    /// Hairline separator reused between the highlight row and the actions, and
    /// between the two action rows, so all three bands read as one surface.
    private var divider: some View {
        Rectangle()
            .fill(theme.borderFaint)
            .frame(height: 1)
            .padding(.horizontal, 2)
    }

    /// The AI row over the plain-text row, split by the same hairline divider.
    /// The padding around the second divider mirrors the gaps around the first
    /// (≈10pt above, ≈12pt below, once each tile's own 4pt inset is counted) so
    /// both separators sit in identical breathing room.
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

    /// The accent-tinted AI actions, four tiles across.
    private var aiActionRow: some View {
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
        }
    }

    /// The plain-text actions. Copy and Share keep the same 1/4 tile width as
    /// the AI row above and stay left-aligned via two hidden placeholder tiles,
    /// so the two tiles line up under the first two AI tiles.
    private var plainTextActionRow: some View {
        HStack(spacing: 4) {
            actionButton(label: "Copy", accent: false, action: onCopy) {
                sfIcon("doc.on.doc", accent: false)
            }
            ShareLink(item: shareText) {
                actionTile(label: "Share", accent: false) {
                    sfIcon("square.and.arrow.up", accent: false)
                }
            }
            .buttonStyle(.plain)
            // Two hidden tiles fill the trailing 1/4 columns so Copy/Share keep
            // the AI row's tile width and stay left-aligned. Hidden tiles (not
            // Spacer/Color.clear) mirror a real tile's footprint exactly, so the
            // row can't stretch the sheet vertically.
            actionPlaceholderTile
            actionPlaceholderTile
        }
    }

    /// An invisible stand-in occupying one tile column — a clear icon plus a
    /// blank label matching a real tile's footprint — used to pad the plain-text
    /// row out to the AI row's four columns so Copy/Share keep the AI tile width.
    private var actionPlaceholderTile: some View {
        actionTile(label: " ", accent: false) {
            Color.clear.frame(width: 18, height: 18)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func sfIcon(_ symbol: String, accent: Bool) -> some View {
        Image(systemName: symbol)
            .font(typography.font(size: 16, weight: .medium))
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
                .font(typography.font(size: 11, weight: .medium))
                .foregroundStyle(accent ? theme.accent : theme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
