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
        // Sized to content and kept over the still-readable reader. The
        // estimated height is shared with the reader's bottom scroll reserve so
        // the two can't drift — see `BibleBottomOverlayKind.estimatedSheetHeight`.
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
                // Inert glass tinted with the colour it paints (so the swatch
                // reads as that colour, not a faint dot); the clear content just
                // sizes the circle. Press feel comes from the press style.
                Button { onHighlight(color) } label: {
                    Color.clear
                        .frame(width: 28, height: 28)
                        .superGlassButton(in: Circle(), tint: color.swatch.color, interactive: false)
                }
                .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
                .accessibilityLabel("Highlight \(color.displayName.lowercased())")
            }
            // Plain theme glass (no tint); the xmark glyph carries the "clear"
            // meaning now that glass owns the edge.
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

    /// The plain-text actions. Copy and Share keep the same 1/4 tile width as
    /// the AI row above and stay left-aligned via two hidden placeholder tiles,
    /// so the two tiles line up under the first two AI tiles.
    private var plainTextActionRow: some View {
        HStack(spacing: 4) {
            actionButton(label: "Copy", accent: false, action: onCopy) {
                sfIcon("doc.on.doc", accent: false)
            }
            // Share goes through ShareLink, but wears the same glass tile + caption.
            actionTile(label: "Share", accent: false) {
                ShareLink(item: shareText) {
                    tileGlassLabel(tint: nil) { sfIcon("square.and.arrow.up", accent: false) }
                }
                .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
                .accessibilityLabel("Share")
            }
            // Two hidden tiles fill the trailing 1/4 columns so Copy/Share keep
            // the AI row's tile width and stay left-aligned. Hidden tiles (not
            // Spacer/Color.clear) mirror a real tile's footprint exactly, so the
            // row can't stretch the sheet vertically.
            actionPlaceholderTile
            actionPlaceholderTile
        }
    }

    /// An invisible stand-in occupying one tile column — a glass-sized button
    /// plus a blank caption matching a real tile's footprint — used to pad the
    /// plain-text row out to the AI row's four columns so Copy/Share keep width.
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

    /// A `Button` whose glass surface fills the tile column, paired with a
    /// caption beneath it. The press style scales just this glass (the label is
    /// a separate caption), so the control shrinks from its own centre and
    /// settles without the release glow interactive glass shows.
    private func actionButton<Icon: View>(
        label: String,
        accent: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        actionTile(label: label, accent: accent) {
            Button(action: action) {
                // AI tiles keep their grouping via a soft-accent glass tint;
                // plain tiles use neutral theme glass.
                tileGlassLabel(tint: accent ? theme.accentSoft : nil, icon: icon)
            }
            .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
            .accessibilityLabel(label)
        }
    }

    /// The glass button's content: an icon centred in a column-wide, ~58pt-tall
    /// inert-glass surface so the control reads as a proper button rather than
    /// an icon chip.
    private func tileGlassLabel<Icon: View>(
        tint: Color?,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        icon()
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .superGlassButton(in: RoundedRectangle(cornerRadius: 16), tint: tint, interactive: false)
    }

    /// A tile column: a glass control over its caption, sharing one width.
    private func actionTile<Control: View>(
        label: String,
        accent: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 8) {
            control()
            // Decorative caption — the control already carries the same string as
            // its accessibilityLabel, so hide this from VoiceOver to avoid a
            // duplicate element/announcement per tile.
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
