import Core
import SwiftUI

struct BibleNavBar: View {
    /// Annotation and chat actions use selected verses when present, otherwise the chapter.
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

    var body: some View {
        // Share one backdrop sample across the glass controls.
        GlassEffectContainer {
            HStack(spacing: 8) {
                // Balance the trailing control; the shell's hamburger occupies this gap.
                Color.clear.frame(width: 44, height: 44)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if showsChapterChevrons, selectionCitation == nil {
                        circleButton(systemImage: "chevron.left", action: onPrevious, morphID: "nav.prev")
                            .disabled(!canStepBackward)
                            .opacity(canStepBackward ? 1 : 0.35)
                            .accessibilityLabel("Previous chapter")
                    }

                    if let selectionCitation, showsSelectionPill {
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

                // No morph ID here, so arrows resolve toward the center pill.
                trailingControl
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
            .buttonStyle(GlassHapticButtonStyle(.selection))
            // Compress the book name before the translation code.
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
                .fixedSize(horizontal: true, vertical: false)
                .font(typography.font(size: 13, weight: .medium))
                .foregroundStyle(theme.inkSoft)
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassHapticButtonStyle(.selection))
            .layoutPriority(1)
            .accessibilityLabel("Translation \(translation.rawValue), choose translation")
        }
        .frame(height: 44)
        .superGlassSurface(in: Capsule(), morph: GlassMorphID("nav.center", in: glassNamespace))
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
