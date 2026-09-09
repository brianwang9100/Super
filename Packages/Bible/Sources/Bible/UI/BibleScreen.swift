import Core
import SwiftUI

public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .headline) private var unavailableSize: CGFloat = 17
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.superEventBus) private var eventBus
    @Environment(\.composerAccessoryStore) private var composerAccessoryStore
    @Bindable private var viewModel: BibleScreenViewModel
    @State private var measuredNavigationHeight: CGFloat = 60

    /// Defer the next sheet until onDismiss; presenting during dismissal is unreliable.
    @State private var pendingSheetHandoff: (position: BiblePosition, action: () -> Void)?

    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    // Keep toasts above the minimized chat pill.
    private let bottomReserve: CGFloat = 100

    private var activeOverlayKind: BibleBottomOverlayKind? {
        if viewModel.isNarrationSheetPresented { return .narration }
        if viewModel.isActionSheetPresented { return .selection }
        return nil
    }

    // Drag dismissal preserves verse selection; changing kind re-presents the shared sheet.
    private var bottomSheetBinding: Binding<BibleBottomOverlayKind?> {
        Binding(
            get: { activeOverlayKind },
            set: { newValue in
                guard newValue == nil else { return }
                if viewModel.isNarrationSheetPresented {
                    viewModel.dismissNarrationSheet()
                } else {
                    viewModel.dismissActionSheet()
                }
            }
        )
    }

    private var bookSheetBinding: Binding<BibleBookSheetViewModel?> {
        Binding(
            get: { viewModel.bookSheet },
            set: { newValue in
                if newValue == nil { viewModel.dismissBookSheet() }
            }
        )
    }

    private var translationSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isTranslationSheetPresented },
            set: { newValue in
                if !newValue { viewModel.dismissTranslationSheet() }
            }
        )
    }

    private var generatingBookIds: Set<String> {
        Set(viewModel.dispatchStatusByTarget.compactMap { spec, status in
            guard spec.target == .book, case .running = status else { return nil }
            return spec.bookId
        })
    }

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
        .task {
            await viewModel.load()
            publishComposerAccessories()
        }
        .onChange(of: viewModel.selectionCitation) { _, _ in
            publishComposerAccessories()
        }
        .onChange(of: viewModel.isRestoringNavigation) { _, _ in
            publishComposerAccessories()
        }
        // Mirror reader visibility to shell chrome only on actual state changes.
        .onChange(of: viewModel.isImmersive) { _, immersive in
            publishChromeVisibility(!immersive)
        }
        // Chapter changes reset scroll; restore chrome so it cannot remain stranded hidden.
        .onChange(of: viewModel.position) { _, _ in
            pendingSheetHandoff = nil
            viewModel.resetImmersive()
            publishComposerAccessories()
        }
        // Other applets must not inherit hidden chrome or stale reader accessories.
        .onDisappear {
            viewModel.dismissNarrationSheet()
            viewModel.resetImmersive()
            publishChromeVisibility(true)
            clearComposerAccessories()
        }
        // Stop background playback while leaving transport open for replay.
        .onChange(of: scenePhase) { _, new in
            if new != .active { viewModel.narration.stop() }
            if new == .background {
                Task { await viewModel.flushNavigationPersistence() }
            }
        }
        .sheet(item: $viewModel.presentedAnnotationTarget) { spec in
            AnnotationSheetContainer(
                spec: spec,
                citation: viewModel.citationLabel(for: spec),
                verseText: viewModel.annotationVerseText(for: spec),
                repository: annotationRepository,
                onClose: { viewModel.dismissAnnotationSheet() },
                onRegenerate: { viewModel.triggerAnnotationGeneration(for: spec) },
                onAddToChat: { record in
                    publishReferenceToChat(
                        viewModel.addAnnotationToChat(record),
                        startNew: false
                    )
                },
                onOpenLink: { link in
                    viewModel.navigateToDeepLink(link)
                },
                onRetry: { viewModel.retryAnnotationGeneration(for: spec) },
                onDeleteFailed: { _ in
                    viewModel.presentDeleteAnnotationFailedToast()
                },
                onClearDraft: { requestID in
                    viewModel.clearAnnotationDraft(for: spec, requestID: requestID)
                },
                dispatchStatus: viewModel.dispatchStatus(for: spec),
                draft: viewModel.annotationDraft(for: spec)
            )
        }
        .sheet(
            isPresented: $viewModel.isAnnotationDisclaimerPresented,
            onDismiss: {
                // Acknowledgement drains the queue before dismissal. Remaining intents therefore
                // identify drag-dismissal without confirmation.
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
        // One sheet item prevents selection and narration presentations from racing.
        .sheet(item: bottomSheetBinding, onDismiss: runPendingSheetHandoff) { kind in
            bottomSheetContent(kind)
        }
        .sheet(item: bookSheetBinding, onDismiss: runPendingSheetHandoff) { sheetViewModel in
            bookPicker(sheetViewModel)
        }
        .sheet(isPresented: translationSheetBinding, onDismiss: runPendingSheetHandoff) {
            translationPicker
        }
    }

    @ViewBuilder
    private func bottomSheetContent(_ kind: BibleBottomOverlayKind) -> some View {
        switch kind {
        case .narration:
            NarrationTransportSheet(
                controller: viewModel.narration,
                citation: viewModel.narrationCitation
                    ?? "\(viewModel.bookName) \(viewModel.position.chapterNumber) (\(viewModel.translation.rawValue))",
                onStop: { viewModel.narration.stop() },
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
                onClose: { withAnimation(motion.animation) { viewModel.dismissActionSheet() } }
            )
        }
    }

    private func addSelectionToChat(startNew: Bool) {
        guard let reference = viewModel.makeVerseReference() else { return }
        publishReferenceToChat(reference, startNew: startNew)
    }

    private func addCurrentChapterToChat(startNew: Bool) {
        guard let reference = viewModel.makeChapterReference() else { return }
        publishReferenceToChat(reference, startNew: startNew)
    }

    // Independent publish tasks can reorder quick flips. The next user-driven scroll
    // or the shell's applet/chat-state reset restores chrome visibility.
    private func publishChromeVisibility(_ visible: Bool) {
        guard let eventBus else { return }
        Task { await eventBus.publish(.shellChromeVisibilityRequested(visible: visible)) }
    }

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
            // Footer visibility hides only arrows; selection reopen/clear controls must remain.
            // Read inside the renderer to stay reactive without republishing.
            shouldHideButtons: { viewModel.isChapterFooterVisible }
        )
    }

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

    private func handleSparkAction(_ action: BibleNavBar.SparkMenuAction) {
        switch action {
        case .annotate:
            if viewModel.selectedVerses.isEmpty {
                viewModel.triggerAnnotationGeneration(for: viewModel.currentChapterAnnotationSpec)
            } else {
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
            showsSelectionPill: composerAccessoryStore == nil,
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
        // Match the shell chrome animation while clearing the measured toolbar and top safe area.
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

    /// Noncontiguous selection generates one intent per contiguous range, in selection order.
    private func handleAnnotateSelection() {
        let ranges = viewModel.selectedAnnotationRanges
        guard !ranges.isEmpty else { return }
        handOffAfterSelectionDismiss {
            for spec in ranges { viewModel.triggerAnnotationGeneration(for: spec) }
        }
    }

    private func handleAddNoteForSelection() {
        guard let spec = viewModel.selectionNoteSpec else { return }
        handOffAfterSelectionDismiss { viewModel.composeNote(for: spec) }
    }

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
            generatingBookIds: generatingBookIds,
            bottomInset: 0
        )
    }

    private func handOffAfterBookSheetDismiss(_ work: @escaping () -> Void) {
        pendingSheetHandoff = (viewModel.position, work)
        viewModel.dismissBookSheet()
    }

    /// Clear selection when dismissing actions; if already closed, run immediately
    /// and leave selection cleanup to the action.
    private func handOffAfterSelectionDismiss(_ work: @escaping () -> Void) {
        guard viewModel.isActionSheetPresented else {
            work()
            return
        }
        pendingSheetHandoff = (viewModel.position, work)
        viewModel.clearSelection()
    }

    private func runPendingSheetHandoff() {
        let pending = pendingSheetHandoff
        pendingSheetHandoff = nil
        guard let pending, pending.position == viewModel.position else { return }
        pending.action()
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
                suppressNarrationScroll: !viewModel.selectedVerses.isEmpty,
                pendingScrollVerse: viewModel.pendingScrollVerse,
                bottomOverlayKind: activeOverlayKind,
                onTapVerse: { number in
                    withAnimation(motion.animation) { viewModel.toggleVerse(number) }
                },
                onPrevious: { viewModel.stepChapter(.previous) },
                onNext: { viewModel.stepChapter(.next) },
                onBackgroundTap: {
                    withAnimation(motion.animation) { viewModel.dismissActionSheet() }
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
                // Selection actions must dismiss before bookmark presentation. Narration stays
                // underneath and is restored by the system when the bookmark sheet closes.
                onBookmarkTap: {
                    if !viewModel.isActionSheetPresented {
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
                },
                topReserve: navigationTopReserve
            )
            .id(viewModel.position)
            .disabled(viewModel.isRestoringNavigation)
            // Chapter swaps must not inherit the picker's dismissal animation.
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
