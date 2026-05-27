import Core
import SwiftUI

/// The Bible reading surface: a floating nav bar over a scrolling column of
/// heading, prose, and poetry paragraphs, ending in prev / next cards.
///
/// All chapter and selection state lives in `BibleScreenViewModel`; the view
/// reads it and renders. The chapter text loads synchronously, so a step
/// repaints at once — only the persisted reading position is written
/// asynchronously. Tapping verses drives the action sheet, whose chat
/// actions publish the selection to the `SuperEventBus` for the Chat
/// composer. The green sparkles menu in the top-right routes the same
/// hand-off paths — selection-aware when verses are selected, whole-chapter
/// otherwise — plus a Narrate (text-to-speech) entry that drives
/// ``NarrationController`` through ``NarrationTransportSheet``.
public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Cross-applet event bus, injected by the shell. `nil` in previews
    /// and isolated tests — the chat hand-off then falls back to the
    /// "coming soon" toast.
    @Environment(\.superEventBus) private var eventBus
    @Bindable private var viewModel: BibleScreenViewModel

    /// Measured intrinsic height of the verse-selection action sheet. The
    /// reader extends its bottom reserve by this amount while verses are
    /// selected so the sheet doesn't cover the last verses of the chapter.
    /// The value can linger after the sheet hides; it's gated by
    /// `selectedVerses.isEmpty` at the read site.
    @State private var actionSheetHeight: CGFloat = 0

    /// How sheets, the action sheet, and the toast animate in and out — a
    /// bottom slide by default, a cross-fade when Reduce Motion is on.
    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    /// Space at the bottom reserved for the shell's minimized chat pill —
    /// the action sheet and toast both clear it, settling a few points above
    /// the pill's drag handle rather than touching it.
    private let bottomReserve: CGFloat = 100

    public init(viewModel: BibleScreenViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            content
            navBar
            bottomOverlay
            if let bookSheet = viewModel.bookSheet {
                bookPicker(bookSheet)
            }
            if viewModel.isTranslationSheetPresented {
                translationPicker
            }
            if let toast = viewModel.toast {
                BibleAttachToast(
                    message: toast,
                    onDismiss: { withAnimation(motion.animation) { viewModel.dismissToast() } }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, bottomReserve)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(motion.transition)
            }
        }
        .task { await viewModel.load() }
        // Foreground-only narration per spec: leaving the app stops
        // playback cleanly so the controller's state matches what the
        // OS would silence anyway.
        .onChange(of: scenePhase) { _, new in
            if new != .active { viewModel.narration.stop() }
        }
        // No `.onChange(narration.state) { dismissCard }` here on
        // purpose: per spec, Stop halts playback but keeps the card up
        // so the user can re-trigger Narrate from the play button. The
        // card hides only via an explicit drag-down on the handle or
        // by tapping the nav-bar speaker again, both wrapped in
        // `withAnimation` so the slide-out is animated.
    }

    /// Hand the current verse selection to the Chat composer over the
    /// `SuperEventBus`. `startNew` picks "New chat" vs. "Add to chat".
    /// Falls back to the "coming soon" toast when no bus is wired.
    private func addSelectionToChat(startNew: Bool) {
        guard let reference = viewModel.makeVerseReference() else { return }
        publishReferenceToChat(reference, startNew: startNew)
    }

    /// Hand the whole current chapter to the Chat composer — the spark
    /// menu's `Add to chat` / `Start a new chat` rows route through here
    /// when no verses are selected.
    private func addCurrentChapterToChat(startNew: Bool) {
        guard let reference = viewModel.makeChapterReference() else { return }
        publishReferenceToChat(reference, startNew: startNew)
    }

    /// Shared publish path used by both selection and whole-chapter
    /// hand-offs. Falls back to the "coming soon" toast when no bus is
    /// wired (previews and isolated tests).
    private func publishReferenceToChat(_ reference: RecordReference, startNew: Bool) {
        guard let eventBus else {
            withAnimation(motion.animation) { viewModel.presentChatComingSoon() }
            return
        }
        Task {
            await eventBus.publish(
                .recordAddedToChat(reference: reference, startNewConversation: startNew)
            )
        }
        withAnimation(motion.animation) {
            viewModel.confirmAddedToChat(citation: reference.citation)
        }
    }

    /// Dispatch a spark-menu action: selection-aware chat hand-off for
    /// the two chat rows, and a Narrate session for the third.
    private func handleSparkAction(_ action: BibleNavBar.SparkMenuAction) {
        switch action {
        case .addToChat:
            if viewModel.selectedVerses.isEmpty {
                addCurrentChapterToChat(startNew: false)
            } else {
                addSelectionToChat(startNew: false)
            }
        case .newChat:
            if viewModel.selectedVerses.isEmpty {
                addCurrentChapterToChat(startNew: true)
            } else {
                addSelectionToChat(startNew: true)
            }
        case .narrate:
            withAnimation(motion.animation) { viewModel.startNarration() }
        }
    }

    private var navBar: some View {
        BibleNavBar(
            bookName: viewModel.bookName,
            chapterNumber: viewModel.position.chapterNumber,
            translation: viewModel.translation,
            selectionCitation: viewModel.selectionCitation,
            canStepBackward: viewModel.canStepBackward,
            canStepForward: viewModel.canStepForward,
            narrationState: viewModel.narration.state,
            narrationCitation: viewModel.narrationCitation,
            onPrevious: { viewModel.stepChapter(.previous) },
            onNext: { viewModel.stepChapter(.next) },
            onPill: { withAnimation(motion.animation) { viewModel.presentBookSheet() } },
            onTranslation: { withAnimation(motion.animation) { viewModel.presentTranslationSheet() } },
            onClearSelection: { withAnimation(motion.animation) { viewModel.clearSelection() } },
            onSparkMenuAction: handleSparkAction,
            onTapNarrationPill: {
                withAnimation(motion.animation) {
                    if viewModel.isNarrationSheetPresented {
                        viewModel.dismissNarrationSheet()
                    } else {
                        viewModel.presentNarrationSheet()
                    }
                }
            }
        )
    }

    /// Bottom-anchored overlay. The narration transport card takes
    /// precedence over the selection action sheet — they're both
    /// bottom-pinned and showing both would visually stack, so while
    /// the card is up the action sheet steps out (selection is still
    /// preserved; it returns once the card is dismissed).
    @ViewBuilder
    private var bottomOverlay: some View {
        if viewModel.isNarrationSheetPresented {
            NarrationTransportSheet(
                controller: viewModel.narration,
                citation: viewModel.narrationCitation
                    ?? "\(viewModel.bookName) \(viewModel.position.chapterNumber) (\(viewModel.translation.rawValue))",
                onStop: { viewModel.narration.stop() },
                // Post-Stop the card stays open; tapping the big play
                // button re-runs the same selection-aware Narrate flow
                // the spark menu's `Narrate` entry triggers.
                onRestart: { viewModel.startNarration() },
                onDismiss: {
                    withAnimation(motion.animation) {
                        viewModel.dismissNarrationSheet()
                    }
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, bottomReserve)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .transition(motion.transition)
        } else if !viewModel.selectedVerses.isEmpty {
            BibleActionSheet(
                citation: viewModel.selectionCitation ?? "",
                shareText: viewModel.selectionShareText ?? "",
                onHighlight: { color in withAnimation(motion.animation) { viewModel.applyHighlight(color) } },
                onClearHighlight: { withAnimation(motion.animation) { viewModel.clearHighlight() } },
                onCopy: { withAnimation(motion.animation) { viewModel.copySelection() } },
                onAddToChat: { addSelectionToChat(startNew: false) },
                onNewChat: { addSelectionToChat(startNew: true) },
                onClose: { withAnimation(motion.animation) { viewModel.clearSelection() } }
            )
            // Measured before the bottomReserve padding so we capture the
            // sheet's intrinsic content height (which grows with Dynamic
            // Type), not the padded distance to the screen edge.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                actionSheetHeight = newHeight
            }
            .padding(.bottom, bottomReserve)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .transition(motion.transition)
        }
    }

    /// A dimmed backdrop plus the translation picker. The picker is a short
    /// sheet that sizes to its rows and anchors to the bottom edge.
    @ViewBuilder
    private var translationPicker: some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(motion.animation) { viewModel.dismissTranslationSheet() } }
            .transition(.opacity)

        BibleTranslationSheet(
            current: viewModel.translation,
            // Lift the sheet's last row above the shell's minimized chat
            // pill, mirroring the reader's 76pt bottom reserve.
            bottomInset: 76,
            onSelect: { translation in
                withAnimation(motion.animation) { viewModel.selectTranslation(translation) }
            },
            onClose: { withAnimation(motion.animation) { viewModel.dismissTranslationSheet() } }
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(motion.transition)
    }

    /// A dimmed backdrop plus the book picker, inset from the top so a sliver
    /// of the reader stays visible behind it. The backdrop fades and the
    /// sheet slides up from the bottom edge.
    @ViewBuilder
    private func bookPicker(_ sheetViewModel: BibleBookSheetViewModel) -> some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(motion.animation) { viewModel.dismissBookSheet() } }
            .transition(.opacity)

        BibleBookSheet(
            viewModel: sheetViewModel,
            currentBookId: viewModel.position.bookId,
            currentChapterNumber: viewModel.position.chapterNumber,
            // Lift the order toggle above the shell's minimized chat pill,
            // mirroring the reader's 76pt bottom reserve.
            bottomInset: 76,
            onSelectChapter: { bookId, chapterNumber in
                withAnimation(motion.animation) {
                    viewModel.selectChapter(bookId: bookId, chapterNumber: chapterNumber)
                }
            },
            onClose: { withAnimation(motion.animation) { viewModel.dismissBookSheet() } }
        )
        .padding(.top, 80)
        .transition(motion.transition)
    }

    @ViewBuilder
    private var content: some View {
        if let chapter = viewModel.chapter, !chapter.paragraphs.isEmpty {
            BibleChapterReader(
                chapter: chapter,
                bookId: viewModel.position.bookId,
                bookName: viewModel.bookName,
                selectedVerses: viewModel.selectedVerses,
                previousLabel: viewModel.previousChapterLabel,
                nextLabel: viewModel.nextChapterLabel,
                currentNarratingVerse: viewModel.narration.currentVerseNumber,
                // Per spec: auto-scroll only when the user hasn't picked
                // a selection of their own.
                suppressNarrationScroll: !viewModel.selectedVerses.isEmpty,
                pendingScrollVerse: viewModel.pendingScrollVerse,
                // Action sheet sits `bottomReserve` (100pt) above the screen
                // bottom; the reader already reserves 76pt for the chat
                // pill, so the extra room needed to lift the chapter footer
                // above the sheet's top edge is its measured height plus
                // the 24pt gap between the chat pill and the sheet bottom.
                // The ternary gates the lingering `actionSheetHeight` so the
                // reserve collapses the instant selection clears.
                bottomOverlayInset: viewModel.selectedVerses.isEmpty
                    ? 0
                    : actionSheetHeight + bottomReserve - 76,
                onTapVerse: { number in
                    withAnimation(motion.animation) { viewModel.toggleVerse(number) }
                },
                onPrevious: { viewModel.stepChapter(.previous) },
                onNext: { viewModel.stepChapter(.next) },
                onClearSelection: {
                    withAnimation(motion.animation) { viewModel.clearSelection() }
                },
                onConsumeScroll: { _ = viewModel.consumePendingScrollVerse() }
            )
            // A fresh identity per chapter resets the scroll offset to the
            // top and re-subscribes the highlight `@Query` when the reader
            // steps.
            .id(viewModel.position)
            // Swap chapters instantly even when the jump happens inside the
            // book picker's slide-down animation transaction.
            .transition(.identity)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            BibleAppletIcon(size: 40)
                .foregroundStyle(theme.inkFaint)
            Text("Chapter unavailable")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    BibleScreen(viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader()))
        .superTheme(.make(.light))
}
