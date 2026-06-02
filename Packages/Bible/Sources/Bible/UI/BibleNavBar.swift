import Core
import SwiftUI

/// The reading surface's top bar: menu, chapter stepping, and the
/// book / translation pill.
///
/// The prev / next arrows step chapters and the pill's two segments open the
/// book and translation pickers. The arrows are pinned to the adjacent edge
/// controls (the leading hamburger placeholder and the trailing action), so
/// the pill's content can grow or shrink without shifting them. When verses
/// are selected (`selectionCitation` is non-`nil`) the arrows step out and
/// the centre slot becomes a citation pill with a clear control. The
/// trailing slot is a green sparkles `Menu` while narration is idle (Add to
/// chat / Start a new chat / Narrate); while narration is speaking or paused
/// the same 36pt green circle stays, the sparkles glyph swaps for a speaker
/// glyph, and tapping it toggles the transport card. The live verse citation
/// is intentionally not shown here — it lives in the transport card's header
/// so the nav bar stays a stable, fixed-width row of three circles.
/// The sidebar entry point is the shell's own floating hamburger, so this
/// bar deliberately has none.
struct BibleNavBar: View {
    /// Action chosen from the green sparkles dropdown menu — the screen
    /// dispatches each to its corresponding view-model / event-bus path.
    enum SparkMenuAction: Sendable, Equatable {
        case addToChat
        case newChat
        case narrate
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let bookName: String
    let chapterNumber: Int
    let translation: BibleTranslation
    /// The selection's citation, or `nil` when no verse is selected — its
    /// presence switches the centre group into selection mode.
    let selectionCitation: String?
    let canStepBackward: Bool
    let canStepForward: Bool
    /// `.idle` shows the sparkles menu; `.speaking` / `.paused` swap it
    /// for the live "Narrating" pill so the user keeps a one-tap path
    /// back to the transport sheet.
    let narrationState: NarrationController.State
    /// Short citation for the verse currently being narrated, e.g.
    /// `"1 Peter 2:9"`. Only read while `narrationState != .idle`.
    let narrationCitation: String?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPill: () -> Void
    let onTranslation: () -> Void
    let onClearSelection: () -> Void
    let onSparkMenuAction: (SparkMenuAction) -> Void
    let onTapNarrationPill: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Balances the trailing `+` so the centre group stays centered;
            // the shell's floating hamburger sits over this gap.
            Color.clear.frame(width: 36, height: 36)

            // Arrows pin to the edge controls (hamburger / plus) rather than
            // to the pill, so chapter / book / translation length never
            // shifts their position. In selection mode the arrows step out
            // and the citation pill takes the full centre slot.
            if selectionCitation == nil {
                circleButton(systemImage: "chevron.left", action: onPrevious)
                    .disabled(!canStepBackward)
                    .opacity(canStepBackward ? 1 : 0.35)
                    .accessibilityLabel("Previous chapter")
            }

            Group {
                if let selectionCitation {
                    selectionPill(selectionCitation)
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        pill
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if selectionCitation == nil {
                circleButton(systemImage: "chevron.right", action: onNext)
                    .disabled(!canStepForward)
                    .opacity(canStepForward ? 1 : 0.35)
                    .accessibilityLabel("Next chapter")
            }

            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(
            // Solid at the top, fading out at the bottom edge so verses
            // scroll cleanly under the bar instead of meeting a hard line.
            LinearGradient(
                colors: [theme.background, theme.background, theme.background.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    /// The book / translation pill — two segments split by a hairline,
    /// matching the 36pt height of the circular nav buttons. The book
    /// segment opens the book picker; the translation segment opens the
    /// translation picker.
    private var pill: some View {
        HStack(spacing: 0) {
            Button(action: onPill) {
                Text("\(bookName) \(chapterNumber)")
                    .font(typography.font(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Lower priority than the translation segment: when the centre
            // slot is tight the book name compresses (and scales) first.
            .layoutPriority(0)
            .accessibilityLabel("\(bookName) \(chapterNumber), choose book")

            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 16)
                .opacity(0.6)

            Button(action: onTranslation) {
                HStack(spacing: 4) {
                    Text(translation.rawValue)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(typography.font(size: 9, weight: .semibold))
                }
                // The translation code is short and never truncates, even
                // when the book segment is scaling down to fit.
                .fixedSize(horizontal: true, vertical: false)
                .font(typography.font(size: 13, weight: .medium))
                .foregroundStyle(theme.inkSoft)
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("Translation \(translation.rawValue), choose translation")
        }
        .frame(height: 36)
        .background(Capsule().fill(theme.backgroundRaised))
        .overlay(Capsule().strokeBorder(theme.borderFaint, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
    }

    /// The selection-mode centre group: the verse citation with a clear
    /// control that drops the whole selection.
    private func selectionPill(_ citation: String) -> some View {
        HStack(spacing: 8) {
            Text(citation)
                .font(typography.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Button(action: onClearSelection) {
                Image(systemName: "xmark")
                    .font(typography.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.inkSoft)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.backgroundSunken))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selection")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(Capsule().fill(theme.backgroundRaised))
        .overlay(Capsule().strokeBorder(theme.borderFaint, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
    }

    /// The trailing-edge control. Switches between the idle sparkles
    /// menu (Add to chat / Start a new chat / Narrate) and the speaker
    /// button that toggles the transport card while narration runs. Same
    /// 36pt green circle in both cases — only the glyph and the tap
    /// handler change, so the bar's geometry stays put. The red
    /// selection dot appears on both forms; the menu's chat actions
    /// remain selection-aware while narration runs.
    @ViewBuilder
    private var trailingControl: some View {
        switch narrationState {
        case .idle:
            sparkMenu
        case .speaking, .paused:
            narrationButton
        }
    }

    private var sparkMenu: some View {
        Menu {
            Button { onSparkMenuAction(.addToChat) } label: {
                Label("Add to chat", systemImage: "paperplane")
            }
            Button { onSparkMenuAction(.newChat) } label: {
                Label("Start a new chat", systemImage: "bubble.left.and.bubble.right")
            }
            Button { onSparkMenuAction(.narrate) } label: {
                Label("Narrate", systemImage: "speaker.wave.2")
            }
        } label: {
            Image(systemName: "sparkles")
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.accent))
                // Soft lift shadow matches the other 36pt nav-bar
                // circles added in PR #76.
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
                .overlay(alignment: .topTrailing) { selectionDotOverlay }
        }
        .menuStyle(.borderlessButton)
        .menuOrder(.fixed)
        .accessibilityLabel(
            selectionCitation == nil
                ? "Chapter actions"
                : "Selection actions"
        )
    }

    private var narrationButton: some View {
        Button(action: onTapNarrationPill) {
            Image(systemName: "speaker.wave.2.fill")
                .font(typography.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.accent))
                // Same soft lift as the sparkles button so the trailing
                // slot's silhouette doesn't change when narration starts.
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
                .overlay(alignment: .topTrailing) { selectionDotOverlay }
        }
        .buttonStyle(.plain)
        // Citation is intentionally not on the visual button — VoiceOver
        // still announces what's playing so the screen reader experience
        // doesn't lose context that the sighted user gets from the card.
        .accessibilityLabel(
            narrationCitation.map { "Narrating \($0). Open transport controls." }
                ?? "Open narration transport controls."
        )
    }

    /// Red dot marking that the user has verses selected — drawn over
    /// both the sparkles menu trigger and the narrating pill so the
    /// signal persists when narration starts on a selection.
    @ViewBuilder
    private var selectionDotOverlay: some View {
        if selectionCitation != nil {
            Circle()
                .fill(theme.errorAccent)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(theme.background, lineWidth: 2))
                .offset(x: 2, y: -2)
        }
    }

    private func circleButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(typography.font(size: 15, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.backgroundRaised))
                .overlay(Circle().strokeBorder(theme.borderFaint, lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}
