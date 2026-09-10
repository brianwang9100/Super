import Core
import SwiftUI

public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.superEventBus) private var eventBus
    @Environment(\.composerAccessoryStore) private var composerAccessoryStore
    @Bindable private var viewModel: BibleScreenViewModel
    @State private var measuredNavigationHeight: CGFloat = 60

    @State private var studyPresentation: BibleStudyPresentationViewModel

    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    // Keep toasts above the minimized chat pill.
    private let bottomReserve: CGFloat = 100

    private var activeOverlayKind: BibleBottomOverlayKind? {
        if viewModel.isNarrationSheetPresented { return .narration }
        if viewModel.isActionSheetPresented { return .selection }
        return nil
    }

    private var selectionSheetBinding: Binding<BibleSelectionSheetViewModel?> {
        Binding(
            get: { viewModel.selectionSheet },
            set: { newValue in
                if newValue == nil { viewModel.dismissSelectionSheet() }
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
            studyPresentation.cancelPendingHandoff()
            viewModel.resetImmersive()
            publishComposerAccessories()
        }
        // Other applets must not inherit hidden chrome or stale reader accessories.
        .onDisappear {
            studyPresentation.invalidate()
            viewModel.narration.stop()
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
        // Stop keeps transport presented for replay; playback state must not dismiss the sheet.
        .modifier(BibleStudySheetsModifier(
            viewModel: viewModel,
            presentation: studyPresentation,
            annotationRepository: annotationRepository,
            narrationContent: { AnyView(narrationSheet) },
            onOpenLink: { viewModel.navigateToDeepLink($0) },
            onAddToChat: { publishReferenceToChat($0, startNew: $1) }
        ))
        .sheet(item: selectionSheetBinding, onDismiss: { studyPresentation.didDismiss(.book, identity: studyIdentity) }) { sheetViewModel in
            bookPicker(sheetViewModel)
                .onAppear { studyPresentation.didPresent(.book, identity: studyIdentity) }
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

    private func addSelectionToChat(startNew: Bool) {
        guard let reference = viewModel.makeVerseReference() else { return }
        publishReferenceToChat(reference, startNew: startNew)
    }

    private func addCurrentChapterToChat(startNew: Bool) {
        guard let reference = viewModel.makeChapterReference() else { return }
        publishReferenceToChat(reference, startNew: startNew)
    }

    /// Independent publish tasks can reorder quick flips. Later scroll changes or shell resets
    /// restore visibility; the shell applies this only while Chat is minimized.
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
            showsChapterChevrons: composerAccessoryStore == nil,
            canStepBackward: viewModel.canStepBackward,
            canStepForward: viewModel.canStepForward,
            narrationState: viewModel.narration.state,
            narrationCitation: viewModel.narrationCitation,
            onPrevious: { viewModel.stepChapter(.previous) },
            onNext: { viewModel.stepChapter(.next) },
            onPill: { withAnimation(motion.animation) { viewModel.presentSelectionSheet() } },
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

    /// Book study actions continue only after the combined selector has finished native dismissal.
    private func bookPicker(_ sheetViewModel: BibleSelectionSheetViewModel) -> some View {
        BibleSelectionSheet(
            viewModel: sheetViewModel,
            onRead: { viewModel.applySelection() },
            onClose: { viewModel.dismissSelectionSheet() },
            onPresentBookAnnotations: { bookId in
                studyPresentation.handOffAfterBookDismiss { viewModel.presentAnnotationSheet(for: .book(bookId: bookId)) }
            },
            onRequestBookAnnotations: { bookId in
                studyPresentation.handOffAfterBookDismiss { viewModel.triggerAnnotationGeneration(for: .book(bookId: bookId)) }
            },
            onPresentBookNotes: { bookId in
                studyPresentation.handOffAfterBookDismiss { viewModel.presentNoteList(for: .book(bookId: bookId)) }
            },
            generatingBookIds: generatingBookIds
        )
        .disabled(viewModel.isRestoringNavigation)
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
