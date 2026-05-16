import Core
import SwiftUI

/// The bottom sheet shown while verses are selected: the passage citation, a
/// highlight-colour row, and the Copy / Share / chat actions.
///
/// The highlight row is presentational only this milestone — the swatches
/// render but do not persist anything; colour application lands with the
/// highlight store. Copy and Share are live; the two chat actions stand in
/// for the deferred hand-off and raise a "coming soon" toast.
struct BibleActionSheet: View {
    @Environment(\.superTheme) private var theme

    /// The selection citation shown in the sheet header, e.g. `"1 Peter 2:9"`.
    let citation: String
    /// The verse text + citation handed to the system share sheet.
    let shareText: String
    let onCopy: () -> Void
    let onAddToChat: () -> Void
    let onNewChat: () -> Void
    let onClose: () -> Void

    /// The five highlight colours, matching the design palette. Presentational
    /// until the highlight store lands.
    private static let swatches: [(name: String, color: OKLCH)] = [
        ("Yellow", OKLCH(0.92, 0.10, 95)),
        ("Green", OKLCH(0.88, 0.09, 150)),
        ("Blue", OKLCH(0.88, 0.06, 235)),
        ("Pink", OKLCH(0.86, 0.08, 350)),
        ("Lavender", OKLCH(0.88, 0.07, 295)),
    ]

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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20).fill(theme.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.borderFaint, lineWidth: 0.5))
        .padding(.horizontal, 8)
    }

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
            ForEach(Self.swatches, id: \.name) { swatch in
                Circle()
                    .fill(swatch.color.color)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(theme.borderFaint, lineWidth: 0.5))
            }
            Circle()
                .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 0.5, dash: [2.5]))
                .background(Circle().fill(theme.backgroundSunken))
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.inkFaint)
                }
        }
        // The swatch row is presentational until the highlight store lands —
        // hidden from VoiceOver so it doesn't announce inert controls.
        .accessibilityHidden(true)
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
