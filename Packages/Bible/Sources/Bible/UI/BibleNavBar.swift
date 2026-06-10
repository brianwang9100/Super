import Core
import SwiftUI

/// The reading surface's top bar: chapter stepping (optional), the book /
/// translation pill, and the trailing action control.
///
/// The prev / next arrows step chapters and the pill's two segments open the
/// book and translation pickers. The arrows flank the pill as one centred glass
/// cluster (a shared `glassEffectID` namespace), with the leading hamburger
/// placeholder and the trailing action pushed to the edges so the cluster stays
/// centred. When verses are selected (`selectionCitation` is non-`nil`) the
/// arrows morph *into* the centre pill and the centre slot becomes a citation
/// pill with a clear control. The trailing slot is a sparkles `Menu` while
/// narration is idle (Annotate / Add to chat / Start a new chat / Narrate);
/// while narration is speaking or paused the same 44pt Liquid Glass circle
/// stays, the sparkles glyph swaps for a speaker glyph, and tapping it toggles
/// the transport card. The sidebar entry point is the shell's own floating
/// hamburger, so this bar deliberately has none.
///
/// `showsChapterChevrons` gates the prev / next arrows. SuperOS keeps them here
/// (the chat opens expanded, so there's no minimized pill to hover above);
/// SuperBible hides them and instead hovers them above the minimized chat
/// composer pill (published through `ComposerAccessoryStore`, rendered by Chat's
/// `ComposerAccessoryFlank`). When hidden, the centre cluster collapses to just
/// the pill and the `onPrevious` / `onNext` / `canStep*` inputs go unused.
struct BibleNavBar: View {
    /// Action chosen from the green sparkles dropdown menu — the screen
    /// dispatches each to its corresponding view-model / event-bus path.
    /// `addToChat` / `newChat` / `annotate` are selection-aware: they act on
    /// the selected verses when any are selected, else on the whole chapter.
    enum SparkMenuAction: Sendable, Equatable {
        case annotate
        case addToChat
        case newChat
        case narrate
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// Shared namespace for the centre cluster's Liquid Glass identities so the
    /// arrows morph into the pill (and the book pill into the citation pill)
    /// when a selection starts or clears.
    @Namespace private var glassNamespace

    let bookName: String
    let chapterNumber: Int
    let translation: BibleTranslation
    /// The selection's citation, or `nil` when no verse is selected — its
    /// presence switches the centre group into selection mode.
    let selectionCitation: String?
    /// Whether the prev / next chapter chevrons render in this bar. SuperOS
    /// passes `true`; SuperBible passes `false` (the chevrons hover above the
    /// chat composer pill instead). When `false`, `canStep*` / `onPrevious` /
    /// `onNext` are unused.
    let showsChapterChevrons: Bool
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
        // A single `GlassEffectContainer` so the row's Liquid Glass elements
        // (arrows, centre pill, trailing control) share one backdrop sample
        // and blend coherently rather than each compositing in isolation.
        GlassEffectContainer {
            HStack(spacing: 8) {
                // Balances the trailing control so the centre cluster stays
                // centered; the shell's floating hamburger sits over this gap
                // and matches its 44pt size.
                Color.clear.frame(width: 44, height: 44)

                Spacer(minLength: 0)

                // The centre cluster: the book / translation pill (or the
                // citation pill while verses are selected, sharing one glass
                // namespace so they morph across the transition), optionally
                // flanked by the prev / next chevrons that hug the pill and
                // morph into it on selection. The flanking `Spacer`s keep the
                // cluster centred and clear of the hamburger gap and the
                // trailing control.
                HStack(spacing: 8) {
                    if showsChapterChevrons, selectionCitation == nil {
                        circleButton(systemImage: "chevron.left", action: onPrevious, morphID: "nav.prev")
                            .disabled(!canStepBackward)
                            .opacity(canStepBackward ? 1 : 0.35)
                            .accessibilityLabel("Previous chapter")
                    }

                    if let selectionCitation {
                        selectionPill(selectionCitation)
                    } else {
                        pill
                    }

                    if showsChapterChevrons, selectionCitation == nil {
                        circleButton(systemImage: "chevron.right", action: onNext, morphID: "nav.next")
                            .disabled(!canStepForward)
                            .opacity(canStepForward ? 1 : 0.35)
                            .accessibilityLabel("Next chapter")
                    }
                }

                Spacer(minLength: 0)

                // Stable island — no morph id, so the arrows resolve toward the
                // centre pill rather than toward this control.
                trailingControl
            }
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
    /// matching the 44pt height of the circular nav buttons. The book
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
        .frame(height: 44)
        .superGlassSurface(in: Capsule(), morph: GlassMorphID("nav.center", in: glassNamespace))
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

            // A plain glyph rather than its own glass chip — nesting glass
            // inside the pill's glass reads muddy, so the clear control sits
            // directly on the pill surface with a roomy tap target.
            Button(action: onClearSelection) {
                Image(systemName: "xmark")
                    .font(typography.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.inkSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selection")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        // Same centre id as the book/translation pill so the two morph into
        // each other across the selection transition.
        .superGlassSurface(in: Capsule(), morph: GlassMorphID("nav.center", in: glassNamespace))
    }

    /// The trailing-edge control. Switches between the idle sparkles
    /// menu (Annotate / Add to chat / Start a new chat / Narrate) and the
    /// speaker button that toggles the transport card while narration runs. Same
    /// 44pt Liquid Glass circle in both cases — only the glyph and the tap
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
            Button { onSparkMenuAction(.annotate) } label: {
                Label("Annotate", systemImage: "text.bubble")
            }
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
                .font(typography.font(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
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
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
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
        action: @escaping () -> Void,
        morphID: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(typography.font(size: 16, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle(), morph: GlassMorphID(morphID, in: glassNamespace))
        }
        .buttonStyle(.plain)
    }
}
