import Foundation
import Observation

/// Coordinates native study-sheet handoffs without cancelling accepted work.
@MainActor
@Observable
final class BibleStudyPresentationViewModel {
    enum Sheet: Hashable {
        case bottom, annotation, disclaimer, note, bookmark, book
    }

    private let viewModel: BibleScreenViewModel
    private(set) var identity = UUID()
    private var isActive = true
    private var isFinishing = false
    private var pendingHandoff: (sheet: Sheet, position: BiblePosition, work: () -> Void)?
    private var dismissing: Set<Sheet> = []
    private var presented: Set<Sheet> = []
    private var completion: (() -> Void)?

    init(viewModel: BibleScreenViewModel) {
        self.viewModel = viewModel
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        isActive && candidate == identity
    }

    /// Starts a new identity so callbacks from the prior presentation are inert.
    func activate() {
        guard !isActive else { return }
        identity = UUID()
        isActive = true
        isFinishing = false
    }

    /// Invalidates presentation work while accepted writes and annotation jobs continue.
    func invalidate() {
        isActive = false
        pendingHandoff = nil
        completion = nil
        dismissing.removeAll()
        presented.removeAll()
    }

    func cancelPendingHandoff() {
        pendingHandoff = nil
    }

    func annotateSelection() {
        let ranges = viewModel.selectedAnnotationRanges
        let translation = viewModel.selectionTranslation
        guard !ranges.isEmpty else { return }
        handOffAfterSelectionDismiss {
            for spec in ranges { self.viewModel.triggerAnnotationGeneration(for: spec, sourceTranslation: translation) }
        }
    }

    func addNoteForSelection() {
        guard let spec = viewModel.selectionNoteSpec else { return }
        handOffAfterSelectionDismiss { self.viewModel.composeNote(for: spec) }
    }

    /// Bookmarks deliberately clear selection; a playing narration remains underneath.
    func presentBookmark(at position: BiblePosition? = nil) {
        let capturedPosition = position ?? viewModel.position
        handOffAfterSelectionDismiss { self.viewModel.presentBookmarkSheet(at: capturedPosition) }
    }

    func handOffAfterBookDismiss(_ work: @escaping () -> Void) {
        guard isActive, !isFinishing else { return }
        guard presented.contains(.book) || dismissing.contains(.book) else {
            viewModel.dismissSelectionSheet()
            work()
            return
        }
        pendingHandoff = (.book, viewModel.position, work)
        dismissing.insert(.book)
        viewModel.dismissSelectionSheet()
    }

    func handOffAfterSelectionDismiss(_ work: @escaping () -> Void) {
        guard isActive, !isFinishing else { return }
        // Narration is the actual visible bottom card when both model flags are set.
        let hasActionPresentation = viewModel.isActionSheetPresented
            || presented.contains(.bottom) || dismissing.contains(.bottom)
        guard hasActionPresentation, !viewModel.isNarrationSheetPresented else {
            work()
            return
        }
        guard presented.contains(.bottom) || dismissing.contains(.bottom) else {
            viewModel.clearSelection()
            work()
            return
        }
        pendingHandoff = (.bottom, viewModel.position, work)
        dismissing.insert(.bottom)
        viewModel.clearSelection()
    }

    /// Inline hosts report visibility directly because UIKit never sends a sheet dismissal.
    func updateInlineBottomVisibility(_ visible: Bool, identity callbackIdentity: UUID) {
        if visible {
            didPresent(.bottom, identity: callbackIdentity)
        } else {
            didDismiss(.bottom, identity: callbackIdentity)
        }
    }

    /// Tracks mounted sheets after interactive dismissal clears their binding.
    func didPresent(_ sheet: Sheet, identity callbackIdentity: UUID) {
        guard isActive, callbackIdentity == identity else { return }
        presented.insert(sheet)
        if isFinishing { dismissing.insert(sheet) }
    }

    func didDismiss(_ sheet: Sheet, identity callbackIdentity: UUID) {
        guard isCurrent(callbackIdentity) else { return }
        dismissing.remove(sheet)
        presented.remove(sheet)
        if isFinishing {
            completeIfDismissed()
        } else if pendingHandoff?.sheet == sheet {
            let pending = pendingHandoff
            pendingHandoff = nil
            guard let pending, pending.position == viewModel.position else { return }
            pending.work()
        }
    }

    /// Completes the outer presentation after every mounted study sheet dismisses.
    func finish(_ onFinish: @escaping () -> Void) {
        guard isActive, !isFinishing else { return }
        isFinishing = true
        pendingHandoff = nil
        completion = onFinish
        // SwiftUI may coalesce unmounted requests without sending `onDismiss`.
        dismissing.formUnion(presented)
        viewModel.dismissNoteList()
        viewModel.dismissBookmarkSheet()
        viewModel.dismissAnnotationSheet()
        viewModel.discardAnnotationDisclaimer()
        viewModel.dismissActionSheet()
        if viewModel.isNarrationSheetPresented { viewModel.dismissNarrationSheet() }
        viewModel.dismissSelectionSheet()
        completeIfDismissed()
    }

    private func completeIfDismissed() {
        guard dismissing.isEmpty else { return }
        let work = completion
        completion = nil
        work?()
    }
}
