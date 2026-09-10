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
    enum MenuAction: Sendable, Equatable {
        case annotate
        case addToChat
        case newChat
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var selectionSize: CGFloat = 13

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
    let onSelectionPill: () -> Void
    let onClearSelection: () -> Void
    let onMenuAction: (MenuAction) -> Void
    let onNarration: () -> Void
    /// Browser history stays separate from biblical chapter stepping.
    let historyControls: HistoryControls
    var isRestoringNavigation = false

    var body: some View {
        // Share one backdrop sample across the glass controls.
        GlassEffectContainer {
            if showsChapterChevrons {
                adaptiveBar(historyControls)
            } else if dynamicTypeSize >= .accessibility4 {
                ViewThatFits(in: .horizontal) {
                    anchoredBar(historyControls)
                    VStack(spacing: 8) {
                        Color.clear.frame(height: 44)
                        navigationPill(historyControls, wraps: true)
                    }
                }
            } else {
                anchoredBar(historyControls)
            }
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

    private func anchoredBar(_ controls: HistoryControls) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Match the shell hamburger's 44pt frame and keep the pill anchored beside it.
            Color.clear.frame(width: 44, height: 44)
            navigationPill(controls, wraps: dynamicTypeSize.isAccessibilitySize)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Probe the ideal row width so the picker cannot squeeze into the utility buttons.
    private func adaptiveBar(_ controls: HistoryControls) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 44, height: 44)
                    .padding(.trailing, 8)
                Spacer(minLength: 0)
                centerControls(controls, wraps: false)
                    .fixedSize(horizontal: true, vertical: false)
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
                }
                centerControls(controls, wraps: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func centerControls(_ controls: HistoryControls, wraps: Bool) -> some View {
        HStack(spacing: 8) {
            if showsChapterChevrons, selectionCitation == nil, !wraps {
                chapterButton(.previous)
            }
            navigationPill(controls, wraps: wraps)
            if showsChapterChevrons, selectionCitation == nil, !wraps {
                chapterButton(.next)
            }
        }
    }

    private func navigationPill(_ controls: HistoryControls, wraps: Bool) -> some View {
        Group {
            if wraps, dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    navigationRow(controls, wraps: wraps)
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 0) {
                        passageControls(controls, wraps: wraps)
                        Rectangle()
                            .fill(theme.border.opacity(0.6))
                            .frame(height: 1)
                            .padding(.horizontal, 12)
                            .accessibilityHidden(true)
                        HStack(spacing: 0) {
                            narrationButton
                            divider
                            actionsMenu
                        }
                    }
                }
            } else {
                navigationRow(controls, wraps: wraps)
            }
        }
        .superGlassSurface(
            in: RoundedRectangle(cornerRadius: 22),
            morph: GlassMorphID("nav.center", in: glassNamespace)
        )
    }

    private func navigationRow(_ controls: HistoryControls, wraps: Bool) -> some View {
        HStack(spacing: 0) {
            passageControls(controls, wraps: wraps)
            divider
            narrationButton
            divider
            actionsMenu
        }
    }

    @ViewBuilder
    private func passageControls(_ controls: HistoryControls, wraps: Bool) -> some View {
        if let selectionCitation, showsSelectionPill {
            selectionControls(selectionCitation, wraps: wraps)
        } else {
            navigationSelector(controls, wraps: wraps)
                .layoutPriority(-1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.border.opacity(0.6))
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
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
            onBack: controls.onBack, onForward: controls.onForward,
            onSelect: onPill
        )
    }

    private func selectionControls(_ citation: String, wraps: Bool) -> some View {
        HStack(spacing: 0) {
            Button(action: onSelectionPill) {
                Text(citation)
                    .font(typography.font(size: selectionSize, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(wraps ? nil : 1)
                    .multilineTextAlignment(.center)
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassHapticButtonStyle(.selection))
            .accessibilityLabel("\(citation), show verse actions")

            Button(action: onClearSelection) {
                Image(systemName: "xmark")
                    .font(typography.font(size: glyphSize * 0.6, weight: .bold))
                    .foregroundStyle(theme.inkSoft)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassHapticButtonStyle(.selection))
            .accessibilityLabel("Clear selection")
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button { onMenuAction(.annotate) } label: {
                Label("Annotate", systemImage: "text.bubble")
            }
            Button { onMenuAction(.addToChat) } label: {
                Label("Add to chat", systemImage: "paperplane")
            }
            Button { onMenuAction(.newChat) } label: {
                Label("Start a new chat", systemImage: "bubble.left.and.bubble.right")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(typography.font(size: glyphSize, weight: .semibold))
                .foregroundStyle(theme.ink)
                .padding(4)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
        Button(action: onNarration) {
            Image(systemName: narrationState == .idle ? "speaker.wave.2" : "speaker.wave.2.fill")
                .font(typography.font(size: glyphSize, weight: .semibold))
                .foregroundStyle(theme.ink)
                .padding(4)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        // Keep the spoken citation accessible even though it is not drawn on this button.
        .accessibilityLabel(
            narrationState == .idle
                ? selectionCitation.map { "Narrate \($0)" } ?? "Narrate chapter"
                : narrationCitation.map { "Narrating \($0). Open transport controls." }
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
                .offset(x: -4, y: 2)
                .accessibilityHidden(true)
        }
    }

    private func circleButton(
        systemImage: String,
        action: @escaping () -> Void,
        morphID: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(typography.font(size: glyphSize, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle(), morph: GlassMorphID(morphID, in: glassNamespace))
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
    }
}
