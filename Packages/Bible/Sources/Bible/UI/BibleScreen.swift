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
    @State private var measuredNavigationHeight: CGFloat = 60

    @State private var studyPresentation: BibleStudyPresentationViewModel

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
        if viewModel.isActionSheetPresented { return .selection }
        return nil
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
        _studyPresentation = State(initialValue: BibleStudyPresentationViewModel(viewModel: viewModel))
    }

    public var body: some View {
        let studyIdentity = studyPresentation.identity
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            chapterContent
            navBar
            if let message = viewModel.navigationPersistenceError {
                BibleAttachToast(
                    message: message,
                    onDismiss: viewModel.canDismissNavigationPersistenceError
                        ? { viewModel.dismissNavigationPersistenceError() } : nil,
                    onRetry: { Task { await viewModel.retryNavigationPersistence() } },
                    systemImage: "clock.arrow.circlepath"
                )
                .disabled(viewModel.isRestoringNavigation)
                .padding(.horizontal, 12)
                .padding(.bottom, bottomReserve)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(motion.transition)
            } else if let toast = viewModel.toast {
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
        .onAppear { studyPresentation.activate() }
        .task {
            await viewModel.load()
            // Publish the prev / next chevrons so they hover above the chat
            // composer pill once the chapter (and its canon-end availability)
            // is loaded.
            publishComposerAccessories()
        }
        .onChange(of: viewModel.selectionCitation) { _, _ in
            publishComposerAccessories()
        }
        .onChange(of: viewModel.isRestoringNavigation) { _, _ in
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
            studyPresentation.cancelPendingHandoff()
            viewModel.resetImmersive()
            // Stepping a chapter can flip the canon-end availability, so
            // refresh the hovering chevrons' enabled state.
            publishComposerAccessories()
        }
        // Leaving the reader restores chrome unconditionally so a non-Bible
        // applet — or a later re-entry — never inherits a hidden state. Clear
        // the composer chevrons too so they don't outlive the reader.
        .onDisappear {
            studyPresentation.invalidate()
            viewModel.dismissNarrationSheet()
            viewModel.resetImmersive()
            publishChromeVisibility(true)
            clearComposerAccessories()
        }
        // Foreground-only narration per spec: leaving the app stops
        // playback cleanly so the controller's state matches what the
        // OS would silence anyway.
        .onChange(of: scenePhase) { _, new in
            if new != .active { viewModel.narration.stop() }
            if new == .background {
                Task { await viewModel.flushNavigationPersistence() }
            }
        }
        // No `.onChange(narration.state) { dismissCard }` here on
        // purpose: per spec, Stop halts playback but keeps the card up
        // so the user can re-trigger Narrate from the play button.
        // Nothing flips `isNarrationSheetPresented` on Stop, so the
        // native sheet stays presented; it hides only on a drag-down or
        // a second nav-bar speaker tap.
        .modifier(BibleStudySheetsModifier(
            viewModel: viewModel,
            presentation: studyPresentation,
            annotationRepository: annotationRepository,
            narrationContent: { AnyView(narrationSheet) },
            onOpenLink: { viewModel.navigateToDeepLink($0) },
            onAddToChat: { publishReferenceToChat($0, startNew: $1) }
        ))
        .sheet(item: bookSheetBinding, onDismiss: { studyPresentation.didDismiss(.book, identity: studyIdentity) }) { sheetViewModel in
            bookPicker(sheetViewModel)
        }
        .sheet(isPresented: translationSheetBinding) {
            translationPicker
        }
    }

    private var narrationSheet: some View {
        NarrationTransportSheet(
            controller: viewModel.narration,
            citation: viewModel.narrationCitation
                ?? "\(viewModel.bookName) \(viewModel.position.chapterNumber) (\(viewModel.translation.rawValue))",
            onStop: { viewModel.narration.stop() },
            onRestart: { viewModel.startNarration() },
            onClose: { viewModel.dismissNarrationSheet() }
        )
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

    /// Publish chapter arrows and selection controls above the chat composer.
    /// Hosts without a store keep those controls in the reader's top bar.
    private func publishComposerAccessories() {
        guard let composerAccessoryStore else { return }
        composerAccessoryStore.buttons = ComposerAccessoryButtons(
            leading: ComposerAccessoryButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Previous chapter",
                isEnabled: !viewModel.isRestoringNavigation && viewModel.canStepBackward,
                action: { viewModel.stepChapter(.previous) }
            ),
            trailing: ComposerAccessoryButton(
                systemImage: "chevron.right",
                accessibilityLabel: "Next chapter",
                isEnabled: !viewModel.isRestoringNavigation && viewModel.canStepForward,
                action: { viewModel.stepChapter(.next) }
            ),
            selection: viewModel.selectionCitation.map { citation in
                ComposerAccessorySelection(
                    title: citation,
                    accessibilityLabel: "\(citation), show verse actions",
                    onExpand: { viewModel.presentActionSheet() },
                    onClear: { withAnimation(motion.animation) { viewModel.clearSelection() } }
                )
            },
            // The footer replaces redundant arrows, but must never take away
            // the selection's reopen / clear controls. Read inside the renderer
            // so scroll visibility stays reactive without republishing.
            shouldHideButtons: { viewModel.isChapterFooterVisible }
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
                // Reuse the tile path, dismissing the action sheet first if
                // it is still open, then firing one intent per range.
                studyPresentation.annotateSelection()
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
            showsSelectionPill: composerAccessoryStore == nil,
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
            onSelectionPill: { withAnimation(motion.animation) { viewModel.presentActionSheet() } },
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
            },
            historyControls: .init(
                backLabel: historyLabel(for: viewModel.backDestination),
                forwardLabel: historyLabel(for: viewModel.forwardDestination),
                onBack: { viewModel.goBack() }, onForward: { viewModel.goForward() }
            ),
            isRestoringNavigation: viewModel.isRestoringNavigation
        )
        .disabled(viewModel.isRestoringNavigation)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            measuredNavigationHeight = height
        }
        // Immersive reading: slide the whole bar up off the top edge and fade
        // it as the user scrolls down into the chapter. The measured hide distance
        // clears the bar plus the top safe area / Dynamic Island. The shell's
        // own chrome (hamburger + chat pill) hides in sympathy off the bus
        // event published below, on the same `chromeReveal` curve so the two
        // move together.
        .offset(y: viewModel.isImmersive ? -navigationHideDistance : 0)
        .opacity(viewModel.isImmersive ? 0 : 1)
        .animation(
            SuperMotion.chrome(hiding: viewModel.isImmersive, reduceMotion: reduceMotion),
            value: viewModel.isImmersive
        )
    }

    /// Reserve every adaptive toolbar row above the chapter heading.
    private var navigationTopReserve: CGFloat { measuredNavigationHeight + 8 }

    /// Clear the measured toolbar and the top safe area when entering immersive mode.
    private var navigationHideDistance: CGFloat { measuredNavigationHeight + 60 }

    private func historyLabel(for position: BiblePosition?) -> String? {
        guard let position, let book = BibleBookCatalog.standard.book(id: position.bookId) else { return nil }
        return "\(book.name) \(position.chapterNumber)"
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
    /// runs from the sheet's `onDismiss` through the shared coordinator so the next
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
                studyPresentation.handOffAfterBookDismiss { viewModel.presentAnnotationSheet(for: .book(bookId: bookId)) }
            },
            onRequestBookAnnotations: { bookId in
                studyPresentation.handOffAfterBookDismiss { viewModel.triggerAnnotationGeneration(for: .book(bookId: bookId)) }
            },
            onPresentBookNotes: { bookId in
                studyPresentation.handOffAfterBookDismiss { viewModel.presentNoteList(for: .book(bookId: bookId)) }
            },
            // Books with an in-flight `.book`-target dispatch — their
            // bubbles render generating. Reading the view model's status
            // map here keeps the picker reactive as dispatches start and
            // finish.
            generatingBookIds: generatingBookIds,
            bottomInset: 0
        )
    }

    private var chapterContent: some View {
        BibleChapterContent(
            viewModel: viewModel,
            layout: .init(topInset: navigationTopReserve, bottomInset: BibleChapterReaderLayout.fullReader.bottomInset),
            navigation: BibleChapterNavigation(
                previousLabel: viewModel.previousChapterLabel,
                nextLabel: viewModel.nextChapterLabel,
                onPrevious: { viewModel.stepChapter(.previous) },
                onNext: { viewModel.stepChapter(.next) }
            ),
            overlayKind: activeOverlayKind,
            currentNarratingVerse: viewModel.narration.currentVerseNumber,
            onAnnotationBubbleTap: { viewModel.presentAnnotationSheet(for: $0) },
            onRequestChapterAnnotation: { viewModel.triggerAnnotationGeneration(for: $0) },
            onNoteGlyphTap: { spec in
                withAnimation(motion.animation) { viewModel.presentNoteList(for: spec) }
            },
            onBookmarkTap: { studyPresentation.presentBookmark() },
            onScroll: { viewModel.updateScroll(offsetY: $0, userDriven: $1) },
            onFooterVisible: { viewModel.updateFooterVisibility($0) }
        )
        .disabled(viewModel.isRestoringNavigation)
    }
}

#Preview {
    BibleScreen(viewModel: BibleScreenViewModel(textLoader: DatabaseBibleTextLoader()))
        .superTheme(.make(.vellumLight))
}
