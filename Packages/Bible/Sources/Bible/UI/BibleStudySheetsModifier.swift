import Core
import SwiftUI

struct BibleStudySheetsModifier: ViewModifier {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BibleScreenViewModel
    let presentation: BibleStudyPresentationViewModel
    var annotationRepository: (any BibleAnnotationRepository)?
    var narrationContent: (() -> AnyView)?
    var inlineNarration = false
    var minimumBottomReserve: CGFloat = 0
    var onBarHeightChange: (CGFloat) -> Void = { _ in }
    var bibleLinkPolicy: MarkdownBibleCitationPolicy = .enabled
    let onOpenLink: (BibleDeepLink) -> Void
    let onAddToChat: (RecordReference, Bool) -> Void

    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    private var activeOverlayKind: BibleBottomOverlayKind? {
        if narrationContent != nil && viewModel.isNarrationSheetPresented { return .narration }
        if viewModel.isActionSheetPresented { return .selection }
        return nil
    }

    private var inlineOverlayKind: BibleBottomOverlayKind? {
        inlineNarration && activeOverlayKind == .narration ? .narration : nil
    }

    private var bottomSheetBinding: Binding<BibleBottomOverlayKind?> {
        Binding(get: { inlineOverlayKind == nil ? activeOverlayKind : nil }, set: { value in
            guard value == nil else { return }
            if !inlineNarration && narrationContent != nil && viewModel.isNarrationSheetPresented {
                viewModel.dismissNarrationSheet()
            } else {
                viewModel.dismissActionSheet()
            }
        })
    }

    func body(content: Content) -> some View {
        let identity = presentation.identity
        content
        .sheet(item: $viewModel.presentedAnnotationTarget, onDismiss: { presentation.didDismiss(.annotation, identity: identity) }) { spec in
            AnnotationSheetContainer(
                spec: spec,
                citation: viewModel.citationLabel(for: spec),
                verseText: viewModel.annotationVerseText(for: spec),
                repository: annotationRepository,
                onClose: { viewModel.dismissAnnotationSheet() },
                onRegenerate: { viewModel.triggerAnnotationGeneration(for: spec) },
                onAddToChat: { record in
                    onAddToChat(viewModel.addAnnotationToChat(record), false)
                },
                onOpenLink: onOpenLink,
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
            .environment(\.markdownBibleCitationPolicy, bibleLinkPolicy)
            .onAppear { presentation.didPresent(.annotation, identity: identity) }
        }
        .sheet(
            isPresented: $viewModel.isAnnotationDisclaimerPresented,
            onDismiss: {
                guard presentation.isCurrent(identity) else { return }
                // Acknowledgement drains the queue; a remaining queue means drag-to-dismiss.
                if !viewModel.pendingAnnotationIntents.isEmpty {
                    viewModel.discardAnnotationDisclaimer()
                }
                presentation.didDismiss(.disclaimer, identity: identity)
            }
        ) {
            AnnotationDisclaimerSheet(
                onGotIt: { viewModel.acknowledgeAnnotationDisclaimer() }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(theme.background)
            .onAppear { presentation.didPresent(.disclaimer, identity: identity) }
        }
        .sheet(item: $viewModel.presentedNoteList, onDismiss: { presentation.didDismiss(.note, identity: identity) }) { presentation in
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
            .onAppear { self.presentation.didPresent(.note, identity: identity) }
        }
        .sheet(item: $viewModel.presentedBookmarkSheet, onDismiss: { presentation.didDismiss(.bookmark, identity: identity) }) { presentation in
            BibleBookmarkSheet(
                citation: presentation.citation,
                currentBookId: presentation.bookId,
                currentChapterNumber: presentation.chapterNumber,
                onSelect: { color in viewModel.toggleBookmark(color: color) },
                onClose: { viewModel.dismissBookmarkSheet() }
            )
            .onAppear { self.presentation.didPresent(.bookmark, identity: identity) }
        }
        // Native actions and inline narration own independent dismissal lifetimes.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if inlineNarration {
                ZStack(alignment: .bottom) {
                    Color.clear.frame(height: minimumBottomReserve)
                    if let kind = inlineOverlayKind {
                        if minimumBottomReserve > 0 {
                            ScrollView {
                                inlineBar(kind, identity: identity)
                            }
                            .defaultScrollAnchor(.bottom, for: .alignment)
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: minimumBottomReserve)
                        } else {
                            inlineBar(kind, identity: identity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: inlineOverlayKind) { old, new in
            if old != nil, new == nil {
                onBarHeightChange(0)
                presentation.updateInlineNarrationVisibility(false, identity: identity)
            }
        }
        .sheet(item: bottomSheetBinding, onDismiss: {
            presentation.didDismiss(.bottom, identity: identity)
        }) { kind in
            bottomSheetContent(kind)
                .onAppear { presentation.didPresent(.bottom, identity: identity) }
        }
    }

    private func inlineBar(_ kind: BibleBottomOverlayKind, identity: UUID) -> some View {
        BibleStudyBar(onHeightChange: onBarHeightChange) { bottomSheetContent(kind) }
            .onAppear { presentation.updateInlineNarrationVisibility(true, identity: identity) }
    }

    @ViewBuilder
    private func bottomSheetContent(_ kind: BibleBottomOverlayKind) -> some View {
        switch kind {
        case .narration:
            if let narrationContent { narrationContent() }
        case .selection:
            BibleActionSheet(
                citation: (viewModel.selectionCitation ?? "")
                    + (inlineNarration ? " (\(viewModel.selectionTranslation.rawValue))" : ""),
                shareText: viewModel.selectionShareText ?? "",
                onHighlight: { color in withAnimation(motion.animation) { viewModel.applyHighlight(color) } },
                onClearHighlight: { withAnimation(motion.animation) { viewModel.clearHighlight() } },
                onCopy: { withAnimation(motion.animation) { viewModel.copySelection() } },
                onNarrate: narrationContent == nil ? nil : {
                    withAnimation(motion.animation) {
                        if inlineNarration { viewModel.dismissActionSheet() }
                        viewModel.startNarration()
                    }
                },
                onAddToChat: { addSelectionToChat(startNew: false) },
                onNewChat: { addSelectionToChat(startNew: true) },
                onAnnotate: { presentation.annotateSelection() },
                onAddNote: { presentation.addNoteForSelection() },
                onClose: { withAnimation(motion.animation) { viewModel.dismissActionSheet() } }
            )
        }
    }

    private func addSelectionToChat(startNew: Bool) {
        guard let reference = viewModel.makeVerseReference() else { return }
        presentation.handOffAfterSelectionDismiss { onAddToChat(reference, startNew) }
    }
}
