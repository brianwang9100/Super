import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var workspaceBodySize: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.superEventBus) private var eventBus
    @Environment(\.composerAccessoryStore) private var composerAccessoryStore
    @Bindable private var viewModel: BibleScreenViewModel
    @Environment(\.appletWorkspaceStore) private var appletWorkspaceStore
    @Environment(\.appletNavigationChromeStore) private var navigationChromeStore
    @Environment(\.bottomControlOccupancyStore) private var bottomControlOccupancyStore
    private let readingWorkspaceEnabled: Bool
    private var usesReadingWorkspace: Bool { readingWorkspaceEnabled }
    private var usesShellNavigation: Bool { usesReadingWorkspace && navigationChromeStore != nil }
    @State private var workspace: BibleReadingWorkspaceViewModel
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
        annotationRepository: (any BibleAnnotationRepository)? = nil,
        readingWorkspaceEnabled: Bool = false,
        readingPreferencesRepository: (any BibleReadingPreferencesRepository)? = nil
    ) {
        self.readingWorkspaceEnabled = readingWorkspaceEnabled
        _workspace = State(initialValue: BibleReadingWorkspaceViewModel(reader: viewModel, preferencesRepository: readingPreferencesRepository))
        self.viewModel = viewModel
        self.annotationRepository = annotationRepository
        _studyPresentation = State(initialValue: BibleStudyPresentationViewModel(viewModel: viewModel))
    }

    public var body: some View {
        let studyIdentity = studyPresentation.identity
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            chapterContent
            if !usesShellNavigation { navBar }
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
                .frame(maxWidth: SuperContentLayout.maximumColumnWidth)
                .padding(.bottom, bottomReserve)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(motion.transition)
            } else if usesReadingWorkspace, let error = workspace.preferenceError {
                BibleAttachToast(message: error, onDismiss: nil, onRetry: { Task { await workspace.retryPreferences() } })
                    .padding(.horizontal, 12)
                    .padding(.bottom, bottomReserve)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            } else if let toast = viewModel.toast {
                BibleAttachToast(
                    message: toast,
                    onDismiss: { withAnimation(motion.animation) { viewModel.dismissToast() } }
                )
                .padding(.horizontal, 12)
                .frame(maxWidth: SuperContentLayout.maximumColumnWidth)
                .padding(.bottom, bottomReserve)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(motion.transition)
            }
        }
        .appletNavigationChrome(isPresented: usesShellNavigation) {
            if usesShellNavigation { navBar }
        }
        .environment(\.bibleReadingLayout, BibleReadingLayout(isPadWorkspace: usesReadingWorkspace))
        .onAppear { studyPresentation.activate() }
        .onChange(of: workspace.mode, initial: true) { _, mode in
            if usesReadingWorkspace { appletWorkspaceStore?.requestedPresentation = mode == .study ? .companion : .singleSurface }
        }
        .onChange(of: appletWorkspaceStore?.isCompanionPresented) { _, presented in
            bottomControlOccupancyStore?.isOccupied = usesReadingWorkspace && activeOverlayKind != nil && presented != true
        }
        .onChange(of: activeOverlayKind, initial: true) { _, kind in
            bottomControlOccupancyStore?.isOccupied = usesReadingWorkspace && kind != nil && appletWorkspaceStore?.isCompanionPresented != true
            if kind == nil { bottomControlOccupancyStore?.measuredHeight = 0 }
        }
        .task {
            await viewModel.load()
            if usesReadingWorkspace { await workspace.load() }
            publishComposerAccessories()
        }
        .onChange(of: viewModel.narrationSessionGeneration) { _, _ in
            if usesReadingWorkspace { workspace.narrationSessionChanged() }
        }
        .onChange(of: viewModel.navigationRestorationGeneration) { _, _ in
            if usesReadingWorkspace { workspace.restoredNavigationChanged() }
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
        // Explicit navigation resets the reading workspace; natural page turns preserve its source.
        .onChange(of: viewModel.explicitNavigationGeneration) { _, _ in
            studyPresentation.cancelPendingHandoff()
            if usesReadingWorkspace { workspace.explicitNavigationChanged() }
            viewModel.resetImmersive()
            publishComposerAccessories()
        }
        // Other applets must not inherit hidden chrome or stale reader accessories.
        .onDisappear {
            appletWorkspaceStore?.requestedPresentation = .singleSurface
            bottomControlOccupancyStore?.isOccupied = false
            bottomControlOccupancyStore?.measuredHeight = 0
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
            inlineNarration: usesReadingWorkspace,
            minimumBottomReserve: usesReadingWorkspace && workspace.mode == .book ? 180 : 0,
            onBarHeightChange: { bottomControlOccupancyStore?.measuredHeight = $0 },
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
            onRestart: { viewModel.restartNarration() },
            onClose: { viewModel.dismissNarrationSheet() },
            inline: usesReadingWorkspace,
            onResumeFollowing: usesReadingWorkspace && workspace.mode == .book && !workspace.isFollowingNarration
                ? { workspace.resumeFollowing() } : nil
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

    private func handleMenuAction(_ action: BibleNavBar.MenuAction) {
        switch action {
        case .annotate:
            if viewModel.selectedVerses.isEmpty {
                viewModel.triggerAnnotationGeneration(for: viewModel.currentChapterAnnotationSpec, sourceTranslation: viewModel.translation)
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
        }
    }

    private var navBar: some View {
        BibleNavBar(
            bookName: viewModel.bookName,
            chapterNumber: viewModel.position.chapterNumber,
            translation: viewModel.translation,
            selectionCitation: viewModel.selectionCitation,
            showsSelectionPill: composerAccessoryStore == nil || appletWorkspaceStore?.isCompanionPresented == true,
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
            onMenuAction: handleMenuAction,
            onNarration: {
                withAnimation(motion.animation) {
                    viewModel.toggleNarrationControls()
                }
            },
            historyControls: .init(
                backLabel: historyLabel(for: viewModel.backDestination),
                forwardLabel: historyLabel(for: viewModel.forwardDestination),
                onBack: { viewModel.goBack() }, onForward: { viewModel.goForward() }
            ),
            isRestoringNavigation: viewModel.isRestoringNavigation || (usesReadingWorkspace && workspace.isRestoring),
            readingMode: usesReadingWorkspace ? workspace.mode : nil,
            onCycleReadingMode: usesReadingWorkspace ? { workspace.selectMode(workspace.mode.next) } : nil,
            centersNavigation: usesReadingWorkspace
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
            onSelect: { viewModel.applySelection() },
            onSelectTranslation: viewModel.selectTranslation,
            onClose: { viewModel.dismissSelectionSheet() },
            onPresentBookAnnotations: { bookId in
                let translation = viewModel.translation
                studyPresentation.handOffAfterBookDismiss { viewModel.presentAnnotationSheet(for: .book(bookId: bookId), sourceTranslation: translation) }
            },
            onRequestBookAnnotations: { bookId in
                let translation = viewModel.translation
                studyPresentation.handOffAfterBookDismiss { viewModel.triggerAnnotationGeneration(for: .book(bookId: bookId), sourceTranslation: translation) }
            },
            onPresentBookNotes: { bookId in
                studyPresentation.handOffAfterBookDismiss { viewModel.presentNoteList(for: .book(bookId: bookId)) }
            },
            generatingBookIds: generatingBookIds
        )
        .disabled(viewModel.isRestoringNavigation)
    }

    @ViewBuilder private var chapterContent: some View {
        if usesReadingWorkspace && workspace.mode == .book {
            BibleBookWorkspace(workspace: workspace, topInset: navigationTopReserve,
                onAnnotation: { viewModel.presentAnnotationSheet(for: $0, sourceTranslation: $1) },
                onNote: { viewModel.presentNoteList(for: $0) },
                onBookmark: { studyPresentation.presentBookmark(at: $0) })
        } else {
            scrollingChapterContent
        }
    }

    @ViewBuilder private var scrollingChapterContent: some View {
        if usesReadingWorkspace && workspace.mode == .compare {
            GeometryReader { geometry in
                chapterReader(comparison: comparisonConfiguration(width: geometry.size.width))
            }
        } else {
            chapterReader(comparison: nil)
        }
    }

    private func comparisonConfiguration(width: CGFloat) -> BibleChapterComparison? {
        guard usesReadingWorkspace, workspace.mode == .compare else { return nil }
        let source = workspace.comparisonSource
        return BibleChapterComparison(
            primaryTranslation: viewModel.translation, secondaryTranslation: workspace.secondaryTranslation,
            chapter: source?.chapter, selectedVerses: source.map { viewModel.selectedVerses(in: $0) } ?? [],
            currentNarratingVerse: source.flatMap { viewModel.narrationVerseNumber(in: $0) },
            stacked: width < 72 + 720 * max(1, workspaceBodySize * typography.fontScale / 24),
            error: workspace.comparisonError,
            onSelectTranslation: { workspace.selectSecondaryTranslation($0) },
            onTapVerse: { number in
                guard let source else { return }
                withAnimation(motion.animation) { viewModel.toggleVerse(number, in: source) }
            },
            onAnnotation: { viewModel.presentAnnotationSheet(for: $0, sourceTranslation: workspace.secondaryTranslation) },
            onRetry: { workspace.refreshComparison() }
        )
    }

    private func chapterReader(comparison: BibleChapterComparison?) -> some View {
        BibleChapterContent(
            viewModel: viewModel,
            layout: .init(topInset: navigationTopReserve, bottomInset: usesReadingWorkspace && activeOverlayKind != nil ? 16 : BibleChapterReaderLayout.fullReader.bottomInset, usesSafeAreaStudyBar: usesReadingWorkspace),
            navigation: BibleChapterNavigation(
                previousLabel: viewModel.previousChapterLabel,
                nextLabel: viewModel.nextChapterLabel,
                onPrevious: { viewModel.stepChapter(.previous) },
                onNext: { viewModel.stepChapter(.next) }
            ),
            comparison: comparison,
            overlayKind: activeOverlayKind,
            currentNarratingVerse: usesReadingWorkspace
                ? viewModel.primarySource.flatMap { viewModel.narrationVerseNumber(in: $0) }
                : viewModel.narration.currentVerseNumber,
            onAnnotationBubbleTap: { viewModel.presentAnnotationSheet(for: $0, sourceTranslation: viewModel.translation) },
            onRequestChapterAnnotation: { viewModel.triggerAnnotationGeneration(for: $0, sourceTranslation: viewModel.translation) },
            onNoteGlyphTap: { spec in
                withAnimation(motion.animation) { viewModel.presentNoteList(for: spec) }
            },
            onBookmarkTap: { studyPresentation.presentBookmark() },
            onScroll: { viewModel.updateScroll(offsetY: $0, userDriven: $1) },
            onFooterVisible: { viewModel.updateFooterVisibility($0) },
            onVisibleVerses: usesReadingWorkspace ? { workspace.rememberVisibleVerses($0) } : nil
        )
        .disabled(viewModel.isRestoringNavigation)
    }
}

#Preview {
    BibleScreen(viewModel: BibleScreenViewModel(textLoader: DatabaseBibleTextLoader()))
        .superTheme(.make(.vellumLight))
}
