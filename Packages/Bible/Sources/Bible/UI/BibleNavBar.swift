import Core
import SwiftUI

/// The reading surface's top bar: chapter stepping (optional), the book /
/// translation pill, and the trailing action control.
///
/// The prev / next arrows step chapters and the pill's two segments open the
/// book and translation pickers. The arrows flank the pill as one centred glass
/// cluster (a shared `glassEffectID` namespace), with the leading hamburger
/// placeholder and the trailing action pushed to the edges so the cluster stays
/// centred. With `showsSelectionPill`, selecting verses morphs the arrows into
/// a citation pill with a clear control. Hosts with bottom selection controls
/// retain the chapter picker here. The trailing slot is a sparkles `Menu` while
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
    /// History availability and actions supplied by the reader.
    struct HistoryControls {
        let backLabel: String?
        let forwardLabel: String?
        let onBack: () -> Void
        let onForward: () -> Void
    }

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
    /// The current selection, used by the action menu and selection indicator.
    /// It replaces the center picker only when `showsSelectionPill` is true.
    let selectionCitation: String?
    /// Hosts with bottom selection controls keep the chapter picker in this bar.
    let showsSelectionPill: Bool
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
    let onSelectionPill: () -> Void
    let onClearSelection: () -> Void
    let onSparkMenuAction: (SparkMenuAction) -> Void
    let onTapNarrationPill: () -> Void
    /// Browser history stays separate from biblical chapter stepping.
    let historyControls: HistoryControls
    var isRestoringNavigation = false

    var body: some View {
        // A single `GlassEffectContainer` so the row's Liquid Glass elements
        // (arrows, centre pill, trailing control) share one backdrop sample
        // and blend coherently rather than each compositing in isolation.
        GlassEffectContainer {
            adaptiveBar(historyControls)
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

    /// Probe the ideal row width so the picker cannot squeeze into the utility buttons.
    private func adaptiveBar(_ controls: HistoryControls) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 44, height: 44)
                Spacer(minLength: 0)
                centerControls(controls, wraps: false)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                trailingControl
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer(minLength: 0)
                    if showsChapterChevrons, selectionCitation == nil {
                        chapterButton(.previous)
                        chapterButton(.next)
                    }
                    Spacer(minLength: 0)
                    trailingControl
                }
                centerControls(controls, wraps: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Keep chapter stepping and selection behavior distinct from the history pair.
    private func centerControls(_ controls: HistoryControls, wraps: Bool) -> some View {
        HStack(spacing: 8) {
            if showsChapterChevrons, selectionCitation == nil, !wraps {
                chapterButton(.previous)
            }
            if let selectionCitation, showsSelectionPill {
                selectionPill(selectionCitation)
            } else {
                navigationSelector(controls, wraps: wraps)
            }
            if showsChapterChevrons, selectionCitation == nil, !wraps {
                chapterButton(.next)
            }
        }
    }

    private func chapterButton(_ direction: BibleChapterDirection) -> some View {
        let isPrevious = direction == .previous
        let isEnabled = isPrevious ? canStepBackward : canStepForward
        return circleButton(
            systemImage: isPrevious ? "chevron.left" : "chevron.right",
            action: isPrevious ? onPrevious : onNext,
            morphID: isPrevious ? "nav.prev" : "nav.next"
        )
        .disabled(!isEnabled || isRestoringNavigation)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(isPrevious ? "Previous chapter" : "Next chapter")
    }

    /// The shared selector owns presentation only; the reader owns navigation state.
    private func navigationSelector(_ controls: HistoryControls, wraps: Bool) -> some View {
        BibleNavigationSelector(
            bookName: bookName, chapterNumber: chapterNumber, translation: translation,
            backLabel: controls.backLabel, forwardLabel: controls.forwardLabel,
            wraps: wraps, isRestoring: isRestoringNavigation,
            morph: GlassMorphID("nav.center", in: glassNamespace),
            onBack: controls.onBack, onForward: controls.onForward,
            onBook: onPill, onTranslation: onTranslation
        )
    }

    /// The citation reopens verse actions; its separate clear control drops
    /// the whole selection.
    private func selectionPill(_ citation: String) -> some View {
        SelectionPill(
            title: citation,
            accessibilityLabel: "\(citation), show verse actions",
            onAction: onSelectionPill,
            onClear: onClearSelection,
            morph: GlassMorphID("nav.center", in: glassNamespace)
        )
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
        case .preparing, .speaking, .paused:
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
        .buttonStyle(GlassHapticButtonStyle(.selection))
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
        .buttonStyle(GlassHapticButtonStyle(.selection))
    }
}
