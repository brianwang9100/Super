import Core
import SwiftUI

struct BibleNavBar: View {
    struct HistoryControls {
        let backLabel: String?
        let forwardLabel: String?
        let onBack: () -> Void
        let onForward: () -> Void
    }

    /// Uses selected verses when present, otherwise the whole chapter.
    enum SparkMenuAction: Sendable, Equatable {
        case annotate
        case addToChat
        case newChat
        case narrate
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    @Namespace private var glassNamespace

    let bookName: String
    let chapterNumber: Int
    let translation: BibleTranslation
    let selectionCitation: String?
    let showsSelectionPill: Bool
    /// Disable when chapter controls are supplied through the composer accessory; step inputs are then unused.
    let showsChapterChevrons: Bool
    let canStepBackward: Bool
    let canStepForward: Bool
    let narrationState: NarrationController.State
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
        // Share one backdrop sample across the glass controls.
        GlassEffectContainer {
            adaptiveBar(historyControls)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(
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

    private func selectionPill(_ citation: String) -> some View {
        SelectionPill(
            title: citation,
            accessibilityLabel: "\(citation), show verse actions",
            onAction: onSelectionPill,
            onClear: onClearSelection,
            morph: GlassMorphID("nav.center", in: glassNamespace)
        )
    }

    // Preserve control geometry while changing idle/playback actions.
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
        // Keep the spoken citation accessible even though it is not drawn on this button.
        .accessibilityLabel(
            narrationCitation.map { "Narrating \($0). Open transport controls." }
                ?? "Open narration transport controls."
        )
    }

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
