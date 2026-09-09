import Core
import Observation

/// Keeps explicit full-reader handoffs and external deep links live while Bible is unmounted.
/// Temporary previews leave the full reader untouched; references sent to Chat use the shell inbox.
@MainActor
@Observable
public final class BibleReferenceInbox {
    private let viewModel: BibleScreenViewModel
    private var subscriptionTask: Task<Void, Never>?
    private var eventCallbacks: [@MainActor () -> Void] = []

    public init(viewModel: BibleScreenViewModel) {
        self.viewModel = viewModel
    }

    // The task holds self weakly; after release, the next event ends the subscription.

    /// Returns after subscription registration, so subsequent publications are received.
    /// Repeated attachment is a no-op.
    public func attach(to bus: SuperEventBus) async {
        guard subscriptionTask == nil else { return }
        let stream = await bus.events()
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: SuperEvent) {
        if case .openRecord(let reference) = event {
            if let target = BibleReaderReference(reference: reference) {
                viewModel.openReference(target)
            } else if let link = BibleDeepLink(reference: reference) {
                viewModel.openReference(
                    bookId: link.bookId,
                    chapterNumber: link.chapter,
                    verseStart: link.verseStart,
                    verseEnd: link.verseEnd
                )
            }
        }
        let callbacks = eventCallbacks
        eventCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    /// Arms synchronously before publication; fires once after processing the next event.
    func _onNextEvent(_ callback: @escaping @MainActor () -> Void) {
        eventCallbacks.append(callback)
    }
}
