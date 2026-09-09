import Foundation
import Observation

/// Coordinates native study-sheet handoffs without owning reading state or accepted writes.
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

    /// Re-entry starts a fresh presentation lifetime; callbacks from the old one are inert.
    func activate() {
        guard !isActive else { return }
        identity = UUID()
        isActive = true
        isFinishing = false
    }

    /// Invalidate presentation work only. Persisted writes and annotation jobs keep running.
    func invalidate() {
        isActive = false
        pendingHandoff = nil
        completion = nil
        dismissing.removeAll()
        presented.removeAll()
    }

    /// Chapter changes invalidate deferred presentation while accepted writes keep running.
    func cancelPendingHandoff() {
        pendingHandoff = nil
    }

    func annotateSelection() {
        let ranges = viewModel.selectedAnnotationRanges
        guard !ranges.isEmpty else { return }
        handOffAfterSelectionDismiss {
            for spec in ranges { self.viewModel.triggerAnnotationGeneration(for: spec) }
        }
    }

    func addNoteForSelection() {
        guard let spec = viewModel.selectionNoteSpec else { return }
        handOffAfterSelectionDismiss { self.viewModel.composeNote(for: spec) }
    }

    /// Bookmarks deliberately clear selection; a playing narration remains underneath.
    func presentBookmark() {
        handOffAfterSelectionDismiss { self.viewModel.presentBookmarkSheet() }
    }

    func handOffAfterBookDismiss(_ work: @escaping () -> Void) {
        guard isActive, !isFinishing else { return }
        guard presented.contains(.book) || dismissing.contains(.book) else {
            viewModel.dismissBookSheet()
            work()
            return
        }
        pendingHandoff = (.book, viewModel.position, work)
        dismissing.insert(.book)
        viewModel.dismissBookSheet()
    }

    private func handOffAfterSelectionDismiss(_ work: @escaping () -> Void) {
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

    /// Track mounted sheets even after a drag gesture has cleared their model binding.
    func didPresent(_ sheet: Sheet, identity callbackIdentity: UUID) {
        guard isActive, callbackIdentity == identity else { return }
        presented.insert(sheet)
        if isFinishing { dismissing.insert(sheet) }
    }

    /// Called by the native sheet's onDismiss, never by a timer or a binding setter.
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

    /// Dismiss the study stack before allowing the host to complete its outer presentation.
    /// Repeated finish requests are ignored; the first captured completion wins.
    func finish(_ onFinish: @escaping () -> Void) {
        guard isActive, !isFinishing else { return }
        isFinishing = true
        pendingHandoff = nil
        completion = onFinish
        // Bindings request presentation; SwiftUI can coalesce an unmounted request
        // away without onDismiss. Only mounted sheets own a native dismissal wait.
        dismissing.formUnion(presented)
        viewModel.dismissNoteList()
        viewModel.dismissBookmarkSheet()
        viewModel.dismissAnnotationSheet()
        viewModel.discardAnnotationDisclaimer()
        viewModel.dismissActionSheet()
        // Preview has no narration contribution. Avoid stopping a full-reader session
        // unless its own host explicitly requests completion.
        if viewModel.isNarrationSheetPresented { viewModel.dismissNarrationSheet() }
        viewModel.dismissBookSheet()
        completeIfDismissed()
    }

    private func completeIfDismissed() {
        guard dismissing.isEmpty else { return }
        let work = completion
        completion = nil
        work?()
    }
}
