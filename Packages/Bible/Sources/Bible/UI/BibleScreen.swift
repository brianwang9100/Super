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
    /// `activeOverlayKind` at the read site.
    @State private var actionSheetHeight: CGFloat = 0

    /// Measured intrinsic height of the narration transport card — the
    /// narration counterpart to `actionSheetHeight`. Feeds the same reader
    /// bottom-reserve so the last verses scroll clear of the card while
    /// narration is presented. Also lingers; gated by `activeOverlayKind`.
    @State private var narrationSheetHeight: CGFloat = 0

    /// How sheets, the action sheet, and the toast animate in and out — a
    /// bottom slide by default, a cross-fade when Reduce Motion is on.
    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    /// Space at the bottom reserved for the shell's minimized chat pill —
    /// the action sheet and toast both clear it, settling a few points above
    /// the pill's drag handle rather than touching it.
    private let bottomReserve: CGFloat = 100

    /// Which bottom card is currently presented, following `bottomOverlay`'s
    /// precedence (narration over selection). Drives both the inset magnitude
    /// and the reader's selection-scroll gate.
    private var activeOverlayKind: BibleBottomOverlayKind? {
        if viewModel.isNarrationSheetPresented { return .narration }
        if !viewModel.selectedVerses.isEmpty { return .selection }
        return nil
    }

    /// Extra bottom reserve the reader adds (on top of its chat-pill clearance)
    /// so the presented card doesn't cover the chapter's last verses. The
    /// measured card height sits `bottomReserve` above the screen bottom and the
    /// reader already reserves `chatPillHeight`, so the extra room needed is the
    /// card's height plus the gap between the pill and the card's bottom edge.
    /// Keyed on `activeOverlayKind` so the lingering measured heights collapse
    /// the instant the card hides.
    private var bottomOverlayInset: CGFloat {
        switch activeOverlayKind {
        case .narration:
            return narrationSheetHeight + bottomReserve - BibleChapterReader.chatPillHeight
        case .selection:
            return actionSheetHeight + bottomReserve - BibleChapterReader.chatPillHeight
        case nil:
            return 0
        }
    }

    /// Book ids whose `.book`-target annotation generation is currently in
    /// flight, derived from the view model's dispatch-status map. Drives the
    /// book picker's generating bubbles. Reading `dispatchStatusByTarget` in
    /// the body keeps the picker reactive as dispatches start and complete.
    private var generatingBookIds: Set<String> {
        Set(viewModel.dispatchStatusByTarget.compactMap { spec, status in
            guard spec.target == .book, case .running = status else { return nil }
            return spec.bookId
        })
    }

    /// Write seam for per-card deletion from the annotation sheet, and
    /// the dependency the `AnnotationSheetContainer` needs for its
    /// mutation callbacks. `nil` in previews / isolated tests — the
    /// sheet then renders without per-card delete (the delete tap is a
    /// silent no-op).
    private let annotationRepository: (any BibleAnnotationRepository)?

    public init(
        viewModel: BibleScreenViewModel,
        annotationRepository: (any BibleAnnotationRepository)? = nil
    ) {
        self.viewModel = viewModel
        self.annotationRepository = annotationRepository
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
        .sheet(item: $viewModel.presentedAnnotationTarget) { spec in
            AnnotationSheetContainer(
                spec: spec,
                citation: viewModel.citationLabel(for: spec),
                catalog: .standard,
                repository: annotationRepository,
                onRegenerate: { viewModel.triggerAnnotationGeneration(for: spec) },
                onAddAllToChat: { records in
                    if let reference = viewModel.makeAnnotationGroupReference(records, for: spec) {
                        publishReferenceToChat(reference, startNew: false)
                    }
                },
                onCardAddToChat: { record in
                    publishReferenceToChat(
                        viewModel.makeAnnotationCardReference(record),
                        startNew: false
                    )
                },
                onOpenReference: { parsed in
                    viewModel.navigateToVerseReference(parsed)
                },
                onRetry: { viewModel.retryAnnotationGeneration(for: spec) },
                onCardDeleteFailed: { _ in
                    viewModel.presentDeleteAnnotationFailedToast()
                },
                onRegenerateFailed: {
                    viewModel.presentRegenerateAnnotationFailedToast(for: spec)
                },
                dispatchStatus: viewModel.dispatchStatus(for: spec)
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(
            isPresented: $viewModel.isAnnotationDisclaimerPresented,
            onDismiss: {
                // `sheet(onDismiss:)` fires on *both* dismissal paths —
                // the user's "Got it" tap (acknowledge) and the
                // drag-down (discard). The two are distinguished by the
                // queue state: acknowledge drains it synchronously
                // before flipping the binding, so an empty queue here
                // means the user acked; a non-empty queue means they
                // drag-dismissed without confirmation.
                //
                // The previous shape called `discardAnnotationDisclaimer()`
                // unconditionally — it was a silent no-op when the queue
                // was already empty, but a future side effect on
                // `discardAnnotationDisclaimer` (telemetry, logging,
                // toast) would have fired on the acknowledge path too.
                // The explicit guard documents the contract.
                if !viewModel.pendingAnnotationIntents.isEmpty {
                    viewModel.discardAnnotationDisclaimer()
                }
            }
        ) {
            AnnotationDisclaimerSheet(
                onGotIt: { viewModel.acknowledgeAnnotationDisclaimer() }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $viewModel.presentedNoteList) { presentation in
            NoteListSheetContainer(
                spec: presentation.spec,
                citation: viewModel.citationLabel(for: presentation.spec),
                autoCompose: presentation.autoCompose,
                onCreate: { body in
                    viewModel.createNote(target: presentation.spec, body: body)
                },
                onUpdate: { id, body in
                    viewModel.updateNote(id: id, body: body)
                },
                onDelete: { id in
                    viewModel.deleteNote(id: id)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
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
    /// wired (previews and isolated tests). On the live path the shell
    /// owns the visible confirmation: the chat overlay semi-expands
    /// from minimized and the composer becomes first responder, so we
    /// only clean up the verse selection here — no toast.
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
            viewModel.clearSelection()
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

    /// Fire a generation intent for each contiguous range in the current
    /// verse selection. A non-contiguous selection (e.g. 28, 30) produces
    /// two independent intents — the disclaimer-gate runs once, then both
    /// fire in selection order. With no selection the spark button is
    /// `.dim` and a tap shouldn't reach this method, but the guard keeps
    /// the call site idempotent if the precondition ever loosens.
    private func handleAnnotateSelection() {
        let ranges = viewModel.selectedAnnotationRanges
        guard !ranges.isEmpty else { return }
        for spec in ranges {
            viewModel.triggerAnnotationGeneration(for: spec)
        }
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
            // Measured before the bottomReserve padding so we capture the
            // card's intrinsic content height (which grows with Dynamic Type),
            // not the padded distance to the screen edge — mirrors the action
            // sheet, so narration insets the reader the same way.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                narrationSheetHeight = newHeight
            }
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
                onAnnotate: { handleAnnotateSelection() },
                onAddNote: { withAnimation(motion.animation) { viewModel.composeNoteForSelection() } },
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
            // pill, mirroring the reader's chat-pill bottom reserve.
            bottomInset: BibleChapterReader.chatPillHeight,
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
            onSelectChapter: { bookId, chapterNumber in
                withAnimation(motion.animation) {
                    viewModel.selectChapter(bookId: bookId, chapterNumber: chapterNumber)
                }
            },
            onSelectVerseRange: { bookId, chapterNumber, verseStart, verseEnd in
                withAnimation(motion.animation) {
                    viewModel.openReference(
                        bookId: bookId, chapterNumber: chapterNumber,
                        verseStart: verseStart, verseEnd: verseEnd
                    )
                }
            },
            onClose: { withAnimation(motion.animation) { viewModel.dismissBookSheet() } },
            onPresentBookAnnotations: { bookId in
                withAnimation(motion.animation) { viewModel.dismissBookSheet() }
                viewModel.presentAnnotationSheet(for: .book(bookId: bookId))
            },
            onRequestBookAnnotations: { bookId in
                // Dismiss the picker first so the disclaimer (or the
                // future generated sheet) lands on the bare reader, not
                // composited over a still-visible picker backdrop.
                // Mirrors the filled-bubble path above.
                withAnimation(motion.animation) { viewModel.dismissBookSheet() }
                viewModel.triggerAnnotationGeneration(for: .book(bookId: bookId))
            },
            onPresentBookNotes: { bookId in
                // Dismiss the picker first so the note list sheet lands on the
                // bare reader, mirroring the annotation paths above.
                withAnimation(motion.animation) { viewModel.dismissBookSheet() }
                viewModel.presentNoteList(for: .book(bookId: bookId))
            },
            onRequestBookNote: { bookId in
                withAnimation(motion.animation) { viewModel.dismissBookSheet() }
                viewModel.composeNote(for: .book(bookId: bookId))
            },
            // Books with an in-flight `.book`-target dispatch — their
            // bubbles render generating. Reading the view model's status
            // map here keeps the picker reactive as dispatches start and
            // finish.
            generatingBookIds: generatingBookIds,
            // Lift the order toggle above the shell's minimized chat pill,
            // mirroring the reader's chat-pill bottom reserve.
            bottomInset: BibleChapterReader.chatPillHeight
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
                // The presented card (selection action sheet or narration
                // transport) reserves room so the chapter footer lifts above
                // its top edge; see `bottomOverlayInset`. `bottomOverlayKind`
                // tells the reader which card it is, so the paired selection
                // scroll runs only for the action sheet and narration's own
                // follow-scroll stays the sole driver while it plays.
                bottomOverlayInset: bottomOverlayInset,
                bottomOverlayKind: activeOverlayKind,
                onTapVerse: { number in
                    withAnimation(motion.animation) { viewModel.toggleVerse(number) }
                },
                onPrevious: { viewModel.stepChapter(.previous) },
                onNext: { viewModel.stepChapter(.next) },
                onClearSelection: {
                    withAnimation(motion.animation) { viewModel.clearSelection() }
                },
                onConsumeScroll: { _ = viewModel.consumePendingScrollVerse() },
                onAnnotationBubbleTap: { spec in
                    viewModel.presentAnnotationSheet(for: spec)
                },
                onRequestChapterAnnotation: { spec in
                    viewModel.triggerAnnotationGeneration(for: spec)
                },
                chapterDispatchStatus: viewModel.dispatchStatus(
                    for: .chapter(
                        bookId: viewModel.position.bookId,
                        chapterNumber: viewModel.position.chapterNumber
                    )
                ),
                onNoteGlyphTap: { spec in
                    withAnimation(motion.animation) { viewModel.presentNoteList(for: spec) }
                },
                onRequestChapterNote: { spec in
                    withAnimation(motion.animation) { viewModel.composeNote(for: spec) }
                }
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
