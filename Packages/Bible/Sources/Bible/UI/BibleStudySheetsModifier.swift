import Core
import SwiftUI

/// Common study sheets; full-reader navigation and narration lifecycle remain with the host.
struct BibleStudySheetsModifier: ViewModifier {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BibleScreenViewModel
    let presentation: BibleStudyPresentationViewModel
    var annotationRepository: (any BibleAnnotationRepository)?
    var narrationContent: (() -> AnyView)?
    var bibleLinkPolicy: MarkdownBibleCitationPolicy = .enabled
    let onOpenLink: (BibleDeepLink) -> Void
    let onAddToChat: (RecordReference, Bool) -> Void

    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    private var activeOverlayKind: BibleBottomOverlayKind? {
        if narrationContent != nil && viewModel.isNarrationSheetPresented { return .narration }
        if viewModel.isActionSheetPresented { return .selection }
        return nil
    }

    private var bottomSheetBinding: Binding<BibleBottomOverlayKind?> {
        Binding(get: { activeOverlayKind }, set: { value in
            guard value == nil else { return }
            if narrationContent != nil && viewModel.isNarrationSheetPresented {
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
        // The verse-selection action sheet and the narration transport share a
        // single `.sheet(item:)` so a `.selection` → `.narration` swap is one
        // sheet re-presenting (rather than two `.sheet` modifiers racing). Each
        // sheet view owns its own presentation (detents, drag indicator,
        // background) via `.sheetPresentation(_:)`, so the call sites just
        // supply content.
        .sheet(item: bottomSheetBinding, onDismiss: { presentation.didDismiss(.bottom, identity: identity) }) { kind in
            bottomSheetContent(kind)
                .onAppear { presentation.didPresent(.bottom, identity: identity) }
        }
    }

    /// The card shown in the shared action / narration sheet, chosen by the
    /// presented `kind`.
    @ViewBuilder
    private func bottomSheetContent(_ kind: BibleBottomOverlayKind) -> some View {
        switch kind {
        case .narration:
            if let narrationContent { narrationContent() }
        case .selection:
            BibleActionSheet(
                citation: viewModel.selectionCitation ?? "",
                shareText: viewModel.selectionShareText ?? "",
                onHighlight: { color in withAnimation(motion.animation) { viewModel.applyHighlight(color) } },
                onClearHighlight: { withAnimation(motion.animation) { viewModel.clearHighlight() } },
                onCopy: { withAnimation(motion.animation) { viewModel.copySelection() } },
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
        onAddToChat(reference, startNew)
    }
}
