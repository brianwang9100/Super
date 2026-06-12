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
/// hand-off paths plus an Annotate entry — all selection-aware when verses
/// are selected, whole-chapter otherwise — plus a Narrate (text-to-speech)
/// entry that drives ``NarrationController`` through ``NarrationTransportSheet``.
public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Base point for the "Chapter unavailable" fallback (== `.headline`),
    /// over a scaled metric so it tracks both Dynamic Type and the slider.
    @ScaledMetric(relativeTo: .headline) private var unavailableSize: CGFloat = 17
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Cross-applet event bus, injected by the shell. `nil` in previews
    /// and isolated tests — the chat hand-off then falls back to the
    /// "coming soon" toast.
    @Environment(\.superEventBus) private var eventBus
    /// Shared holder for the chat composer's hovering flank buttons, injected by
    /// the shell on targets that opt in (SuperBible). The reader publishes its
    /// previous / next chapter chevrons here so they render above the composer
    /// pill. `nil` on SuperOS, in previews, and in isolated tests — publishing
    /// is then a no-op and the chevrons simply don't appear.
    @Environment(\.composerAccessoryStore) private var composerAccessoryStore
    @Bindable private var viewModel: BibleScreenViewModel

    /// Work to run once the currently-presented sheet finishes dismissing.
    /// Presenting a second native sheet while the first is still dismissing is
    /// unreliable, so cross-sheet hand-offs — the book picker's annotation /
    /// note rows, and the action sheet's Annotate / Add-note tiles — record the
    /// follow-on presentation here, dismiss the current sheet, and run it from
    /// that sheet's `onDismiss` (`runPendingSheetHandoff`). Shared by the book
    /// sheet and the action / narration sheet since only one is ever up.
    @State private var pendingSheetHandoff: (() -> Void)?

    /// How the toast and the picker state flips animate in and out — a bottom
    /// slide by default, a cross-fade when Reduce Motion is on. (The migrated
    /// sheets animate themselves; this drives the toast and the `withAnimation`
    /// wrappers around selection / picker mutations.)
    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    /// Space at the bottom reserved for the shell's minimized chat pill — the
    /// toast clears it, settling a few points above the pill's drag handle
    /// rather than touching it.
    private let bottomReserve: CGFloat = 100

    /// Which bottom sheet is currently presented, with narration taking
    /// precedence over the verse selection. Doubles as the `.sheet(item:)`
    /// item for the combined action / narration sheet and as the reader's
    /// selection-scroll gate.
    private var activeOverlayKind: BibleBottomOverlayKind? {
        if viewModel.isNarrationSheetPresented { return .narration }
        if !viewModel.selectedVerses.isEmpty { return .selection }
        return nil
    }

    /// `.sheet(item:)` binding for the combined action / narration sheet. The
    /// item follows `activeOverlayKind`; a `nil` set (the user dragged the
    /// sheet down) dismisses whichever card is up — narration first, else the
    /// selection. A `.selection` → `.narration` swap changes the item's
    /// identity, so the sheet re-presents with the other card, mirroring the
    /// old "narration steps over the action sheet" precedence.
    private var bottomSheetBinding: Binding<BibleBottomOverlayKind?> {
        Binding(
            get: { activeOverlayKind },
            set: { newValue in
                // `.sheet(item:)` only writes `nil` here (the user drag-dismissed);
                // non-nil writes are SwiftUI-internal, so there's nothing to do.
                guard newValue == nil else { return }
                if viewModel.isNarrationSheetPresented {
                    viewModel.dismissNarrationSheet()
                } else {
                    viewModel.clearSelection()
                }
            }
        )
    }

    /// `.sheet(item:)` binding for the book picker. `bookSheet` is `private(set)`
    /// on the view model, so the dismiss path routes through `dismissBookSheet()`
    /// rather than writing the property directly.
    private var bookSheetBinding: Binding<BibleBookSheetViewModel?> {
        Binding(
            get: { viewModel.bookSheet },
            set: { newValue in
                if newValue == nil { viewModel.dismissBookSheet() }
            }
        )
    }

    /// `.sheet(isPresented:)` binding for the translation picker, routing the
    /// dismiss path through `dismissTranslationSheet()` for the same reason.
    private var translationSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isTranslationSheetPresented },
            set: { newValue in
                if !newValue { viewModel.dismissTranslationSheet() }
            }
        )
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
        .task {
            await viewModel.load()
            // Publish the prev / next chevrons so they hover above the chat
            // composer pill once the chapter (and its canon-end availability)
            // is loaded.
            publishComposerAccessories()
        }
        // Immersive reading: when the scroll reducer flips `isImmersive`,
        // mirror it to the shell so its hamburger + chat pill hide/show in
        // sympathy with the local nav bar. Published only on real flips
        // (`updateScroll` is idempotent), matching the bus's low-frequency
        // event style.
        .onChange(of: viewModel.isImmersive) { _, immersive in
            publishChromeVisibility(!immersive)
        }
        // Stepping chapters re-identifies the reader and resets its scroll to
        // the top; clear immersive so chrome can't strand hidden (the
        // `isImmersive` change above restores the shell's chrome too).
        .onChange(of: viewModel.position) { _, _ in
            viewModel.resetImmersive()
            // Stepping a chapter can flip the canon-end availability, so
            // refresh the hovering chevrons' enabled state.
            publishComposerAccessories()
        }
        // Leaving the reader restores chrome unconditionally so a non-Bible
        // applet — or a later re-entry — never inherits a hidden state. Clear
        // the composer chevrons too so they don't outlive the reader.
        .onDisappear {
            viewModel.resetImmersive()
            publishChromeVisibility(true)
            clearComposerAccessories()
        }
        // Foreground-only narration per spec: leaving the app stops
        // playback cleanly so the controller's state matches what the
        // OS would silence anyway.
        .onChange(of: scenePhase) { _, new in
            if new != .active { viewModel.narration.stop() }
        }
        // No `.onChange(narration.state) { dismissCard }` here on
        // purpose: per spec, Stop halts playback but keeps the card up
        // so the user can re-trigger Narrate from the play button.
        // Nothing flips `isNarrationSheetPresented` on Stop, so the
        // native sheet stays presented; it hides only on a drag-down or
        // a second nav-bar speaker tap.
        .sheet(item: $viewModel.presentedAnnotationTarget) { spec in
            AnnotationSheetContainer(
                spec: spec,
                citation: viewModel.citationLabel(for: spec),
                catalog: .standard,
                repository: annotationRepository,
                onClose: { viewModel.dismissAnnotationSheet() },
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
                    viewModel.clearFailedDispatchStatus(for: spec)
                },
                dispatchStatus: viewModel.dispatchStatus(for: spec)
            )
            // Detents / drag indicator / themed background now ride with the
            // sheet view via `.sheetPresentation(.expandable)` (matching the
            // book / translation / action / narration sheets).
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
            .presentationDragIndicator(.visible)
            .presentationBackground(theme.background)
        }
        .sheet(item: $viewModel.presentedNoteList) { presentation in
            NoteListSheetContainer(
                spec: presentation.spec,
                citation: viewModel.citationLabel(for: presentation.spec),
                autoCompose: presentation.autoCompose,
                onClose: { viewModel.dismissNoteList() },
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
            // Detents / drag indicator / themed background now ride with the
            // sheet view via `.sheetPresentation(.expandable)`.
        }
        .sheet(item: $viewModel.presentedBookmarkSheet) { presentation in
            BibleBookmarkSheet(
                citation: presentation.citation,
                currentBookId: presentation.bookId,
                currentChapterNumber: presentation.chapterNumber,
                onSelect: { color in viewModel.toggleBookmark(color: color) },
                onClose: { viewModel.dismissBookmarkSheet() }
            )
        }
        // The verse-selection action sheet and the narration transport share a
        // single `.sheet(item:)` so a `.selection` → `.narration` swap is one
        // sheet re-presenting (rather than two `.sheet` modifiers racing). Each
        // sheet view owns its own presentation (detents, drag indicator,
        // background) via `.sheetPresentation(_:)`, so the call sites just
        // supply content.
        .sheet(item: bottomSheetBinding, onDismiss: runPendingSheetHandoff) { kind in
            bottomSheetContent(kind)
        }
        .sheet(item: bookSheetBinding, onDismiss: runPendingSheetHandoff) { sheetViewModel in
            bookPicker(sheetViewModel)
        }
        // Carries `onDismiss: runPendingSheetHandoff` like the other sheets for
        // consistency: no translation row queues a hand-off today, but matching
        // the deferral wiring keeps a future one from silently dropping it.
        .sheet(isPresented: translationSheetBinding, onDismiss: runPendingSheetHandoff) {
            translationPicker
        }
    }

    /// The card shown in the shared action / narration sheet, chosen by the
    /// presented `kind`.
    @ViewBuilder
    private func bottomSheetContent(_ kind: BibleBottomOverlayKind) -> some View {
        switch kind {
        case .narration:
            NarrationTransportSheet(
                controller: viewModel.narration,
                citation: viewModel.narrationCitation
                    ?? "\(viewModel.bookName) \(viewModel.position.chapterNumber) (\(viewModel.translation.rawValue))",
                onStop: { viewModel.narration.stop() },
                // Post-Stop the card stays open; tapping the big play
                // button re-runs the same selection-aware Narrate flow
                // the spark menu's `Narrate` entry triggers.
                onRestart: { viewModel.startNarration() },
                onClose: { viewModel.dismissNarrationSheet() }
            )
        case .selection:
            BibleActionSheet(
                citation: viewModel.selectionCitation ?? "",
                shareText: viewModel.selectionShareText ?? "",
                onHighlight: { color in withAnimation(motion.animation) { viewModel.applyHighlight(color) } },
                onClearHighlight: { withAnimation(motion.animation) { viewModel.clearHighlight() } },
                onCopy: { withAnimation(motion.animation) { viewModel.copySelection() } },
                onAddToChat: { addSelectionToChat(startNew: false) },
                onNewChat: { addSelectionToChat(startNew: true) },
                onAnnotate: { handleAnnotateSelection() },
                onAddNote: { handleAddNoteForSelection() },
                onClose: { withAnimation(motion.animation) { viewModel.clearSelection() } }
            )
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
    /// Ask the shell to hide (`false`) or restore (`true`) its global chrome —
    /// the hamburger and the minimized chat pill — so the reader can claim the
    /// full screen in immersive mode. A no-op without a bus (previews /
    /// isolated tests); the shell only complies while the chat is a pill and
    /// otherwise leaves its chrome put.
    ///
    /// Each call is an independent unstructured `Task`, so two flips in quick
    /// succession have no delivery-order guarantee. That's acceptable here: the
    /// reducer's hysteresis debounces flips to roughly one per scroll-direction
    /// change, and an out-of-order pair self-heals on the next user-driven
    /// scroll sample (or the shell's applet-switch / chat-state reset). It only
    /// ever lands on a *stale* boolean, never a wrong one.
    private func publishChromeVisibility(_ visible: Bool) {
        guard let eventBus else { return }
        Task { await eventBus.publish(.shellChromeVisibilityRequested(visible: visible)) }
    }

    /// Publish the reader's previous / next chapter chevrons into the shared
    /// composer-accessory store so they hover above the chat composer pill
    /// (leading = previous, trailing = next). The `isEnabled` flags track the
    /// canon ends and the actions step the chapter. A no-op without a store
    /// (SuperOS, previews, isolated tests) — the chevrons then simply don't
    /// appear, and the in-reader footer prev / next cards remain the only
    /// stepping affordance.
    private func publishComposerAccessories() {
        guard let composerAccessoryStore else { return }
        composerAccessoryStore.buttons = ComposerAccessoryButtons(
            leading: ComposerAccessoryButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Previous chapter",
                isEnabled: viewModel.canStepBackward,
                action: { viewModel.stepChapter(.previous) }
            ),
            trailing: ComposerAccessoryButton(
                systemImage: "chevron.right",
                accessibilityLabel: "Next chapter",
                isEnabled: viewModel.canStepForward,
                action: { viewModel.stepChapter(.next) }
            ),
            // Hide the hovering chevrons once the chapter's own prev / next
            // footer cards scroll into view — they'd be redundant. Read inside
            // the renderer's body, so this stays reactive as the user scrolls
            // without republishing.
            shouldHide: { viewModel.isChapterFooterVisible }
        )
    }

    /// Clear the composer flank chevrons when the reader leaves so a non-Bible
    /// backdrop never inherits them.
    private func clearComposerAccessories() {
        composerAccessoryStore?.buttons = .none
    }

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

    /// Dispatch a spark-menu action: selection-aware annotation and chat
    /// hand-off (selected verses when any are selected, else the whole
    /// chapter), plus a Narrate session.
    private func handleSparkAction(_ action: BibleNavBar.SparkMenuAction) {
        switch action {
        case .annotate:
            if viewModel.selectedVerses.isEmpty {
                // No sheet is up — trigger directly, mirroring the chapter
                // reader's "generate" bubble. First run shows the disclaimer.
                viewModel.triggerAnnotationGeneration(for: viewModel.currentChapterAnnotationSpec)
            } else {
                // The action sheet is up over the reader; reuse the tile path
                // which dismisses it first, then fires one intent per range.
                handleAnnotateSelection()
            }
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
            // SuperBible (a composer-accessory store is injected) hovers the
            // chevrons above the chat composer pill, so the bar hides them;
            // SuperOS (no store) keeps them in the bar.
            showsChapterChevrons: composerAccessoryStore == nil,
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
        // Immersive reading: slide the whole bar up off the top edge and fade
        // it as the user scrolls down into the chapter. `navBarHideDistance`
        // clears the bar plus the top safe area / Dynamic Island. The shell's
        // own chrome (hamburger + chat pill) hides in sympathy off the bus
        // event published below, on the same `chromeReveal` curve so the two
        // move together.
        .offset(y: viewModel.isImmersive ? -Self.navBarHideDistance : 0)
        .opacity(viewModel.isImmersive ? 0 : 1)
        .animation(
            SuperMotion.chrome(hiding: viewModel.isImmersive, reduceMotion: reduceMotion),
            value: viewModel.isImmersive
        )
    }

    /// How far up to slide the nav bar when it hides — its own height plus a
    /// generous allowance for the top safe area / Dynamic Island so it clears
    /// the screen on every iPhone.
    private static let navBarHideDistance: CGFloat = 120

    /// Fire a generation intent for each contiguous range in the current
    /// verse selection. A non-contiguous selection (e.g. 28, 30) produces
    /// two independent intents — the disclaimer-gate runs once, then both
    /// fire in selection order. With no selection the spark button is
    /// `.dim` and a tap shouldn't reach this method, but the guard keeps
    /// the call site idempotent if the precondition ever loosens.
    private func handleAnnotateSelection() {
        let ranges = viewModel.selectedAnnotationRanges
        guard !ranges.isEmpty else { return }
        // Annotate hands off to the first-run disclaimer sheet (and clears the
        // selection like the other tiles), so dismiss the action sheet first and
        // fire the generation from `onDismiss` — presenting the disclaimer while
        // the action sheet is still up would stack two sheets.
        handOffAfterSelectionDismiss {
            for spec in ranges { viewModel.triggerAnnotationGeneration(for: spec) }
        }
    }

    /// Action sheet "Add note" — compose a note on the selection's bounding
    /// range. Dismisses the action sheet first, then presents the note editor
    /// from `onDismiss` so the two sheets don't race.
    private func handleAddNoteForSelection() {
        guard let spec = viewModel.selectionNoteSpec else { return }
        handOffAfterSelectionDismiss { viewModel.composeNote(for: spec) }
    }

    /// The translation picker content, presented as a native `.sheet`. Sizes to
    /// its rows via the compact detent; no chat-pill inset since the sheet may
    /// cover the pill.
    private var translationPicker: some View {
        BibleTranslationSheet(
            current: viewModel.translation,
            bottomInset: 0,
            onSelect: { translation in
                viewModel.selectTranslation(translation)
            },
            onClose: { viewModel.dismissTranslationSheet() }
        )
    }

    /// The book picker content, presented as a native `.sheet`. The annotation /
    /// note rows record a deferred hand-off and dismiss the picker; the hand-off
    /// runs from the sheet's `onDismiss` (`runPendingSheetHandoff`) so the next
    /// sheet presents onto the bare reader rather than racing the picker's
    /// dismissal.
    private func bookPicker(_ sheetViewModel: BibleBookSheetViewModel) -> some View {
        BibleBookSheet(
            viewModel: sheetViewModel,
            currentBookId: viewModel.position.bookId,
            currentChapterNumber: viewModel.position.chapterNumber,
            onSelectChapter: { bookId, chapterNumber in
                viewModel.selectChapter(bookId: bookId, chapterNumber: chapterNumber)
            },
            onSelectVerseRange: { bookId, chapterNumber, verseStart, verseEnd in
                viewModel.openReference(
                    bookId: bookId, chapterNumber: chapterNumber,
                    verseStart: verseStart, verseEnd: verseEnd
                )
            },
            onClose: { viewModel.dismissBookSheet() },
            onPresentBookAnnotations: { bookId in
                handOffAfterBookSheetDismiss { viewModel.presentAnnotationSheet(for: .book(bookId: bookId)) }
            },
            onRequestBookAnnotations: { bookId in
                handOffAfterBookSheetDismiss { viewModel.triggerAnnotationGeneration(for: .book(bookId: bookId)) }
            },
            onPresentBookNotes: { bookId in
                handOffAfterBookSheetDismiss { viewModel.presentNoteList(for: .book(bookId: bookId)) }
            },
            // Books with an in-flight `.book`-target dispatch — their
            // bubbles render generating. Reading the view model's status
            // map here keeps the picker reactive as dispatches start and
            // finish.
            generatingBookIds: generatingBookIds,
            bottomInset: 0
        )
    }

    /// Queue `work` and dismiss the book picker; `work` fires from the picker's
    /// `onDismiss` so the follow-on sheet lands on the bare reader.
    private func handOffAfterBookSheetDismiss(_ work: @escaping () -> Void) {
        pendingSheetHandoff = work
        viewModel.dismissBookSheet()
    }

    /// Queue `work` and clear the selection (dismissing the action sheet);
    /// `work` fires from the action sheet's `onDismiss` for the same reason.
    private func handOffAfterSelectionDismiss(_ work: @escaping () -> Void) {
        pendingSheetHandoff = work
        viewModel.clearSelection()
    }

    /// Run (and clear) the hand-off queued before the current sheet dismissed.
    /// A no-op when no hand-off was queued (a plain drag-dismiss).
    private func runPendingSheetHandoff() {
        let work = pendingSheetHandoff
        pendingSheetHandoff = nil
        work?()
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
                // `bottomOverlayKind` tells the reader which sheet is up so its
                // paired selection scroll runs only for the action sheet —
                // lifting the just-selected verse clear of the sheet — while
                // narration's own follow-scroll stays the sole driver as it
                // plays. It also sizes the reader's bottom scroll reserve to the
                // presented sheet's height, so the last verses scroll clear of
                // the floating, scrim-less sheet instead of hiding behind it.
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
                    for: viewModel.currentChapterAnnotationSpec
                ),
                onNoteGlyphTap: { spec in
                    withAnimation(motion.animation) { viewModel.presentNoteList(for: spec) }
                },
                // With the action sheet up (its readable background keeps the
                // title tappable), presenting the bookmark sheet directly
                // would race the action sheet's dismissal — the documented
                // unreliable case — so it routes through the hand-off and
                // presents from the action sheet's `onDismiss`. The narration
                // transport needs no hand-off: it stays presented and the
                // system restores it when the bookmark sheet closes, the same
                // interleaving the note glyph relies on.
                onBookmarkTap: {
                    if viewModel.selectedVerses.isEmpty {
                        viewModel.presentBookmarkSheet()
                    } else {
                        handOffAfterSelectionDismiss { viewModel.presentBookmarkSheet() }
                    }
                },
                onScroll: { offsetY, userDriven in
                    viewModel.updateScroll(offsetY: offsetY, userDriven: userDriven)
                },
                onFooterVisible: { visible in
                    viewModel.updateFooterVisibility(visible)
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
                .font(typography.font(size: unavailableSize, weight: .semibold, design: .serif))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    BibleScreen(viewModel: BibleScreenViewModel(textLoader: DatabaseBibleTextLoader()))
        .superTheme(.make(.vellumLight))
}
