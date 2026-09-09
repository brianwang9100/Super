import Core
import Foundation
import Observation

/// Owns one chapter preview's presentation lifetime and completion.
@MainActor
@Observable
final class BibleChapterPreviewViewModel {
    let identity = UUID()
    let reader: BibleScreenViewModel
    let study: BibleStudyPresentationViewModel
    private(set) var isReady = false
    private var isActive = true
    private var isFinishing = false
    private var onFinish: (@MainActor (RecordPreviewCompletion) -> Void)?

    init(reader: BibleScreenViewModel, onFinish: @escaping @MainActor (RecordPreviewCompletion) -> Void) {
        self.reader = reader
        self.study = BibleStudyPresentationViewModel(viewModel: reader)
        self.onFinish = onFinish
    }

    /// Accepts only this native presentation's first successful completion.
    func presentationDidComplete(identity: UUID) {
        guard identity == self.identity, isActive, !isFinishing, !isReady else { return }
        isReady = true
        reader.presentActionSheet()
    }

    func reopenActions() {
        guard isActive, !isFinishing, isReady else { return }
        reader.presentActionSheet()
    }

    /// Cancels presentation work only; repositories and the shared dispatcher keep accepted work.
    func invalidate() {
        isActive = false
        isReady = false
        onFinish = nil
        study.invalidate()
    }

    func cancel() { finish(.cancel) }

    func openInBible() {
        let target = BibleReaderReference(position: reader.position, translation: reader.translation,
                                          selectedVerses: reader.selectedVerses)
        finish(.openRecord(reference: target.recordReference))
    }

    func addToChat(reference: RecordReference, startNewConversation: Bool) {
        finish(.addToChat(reference: reference, startNewConversation: startNewConversation))
    }

    private func finish(_ completion: RecordPreviewCompletion) {
        guard isActive, !isFinishing else { return }
        isFinishing = true
        isReady = false
        study.finish { [weak self] in
            guard let self, isActive else { return }
            let callback = onFinish
            invalidate()
            callback?(completion)
        }
    }
}
