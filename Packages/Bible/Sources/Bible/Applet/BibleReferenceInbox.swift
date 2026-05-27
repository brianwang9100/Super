import Core
import Observation

/// App-session-lived subscriber that routes inbound Bible verse-range
/// references (from Chat citation taps and external `super://bible/...`
/// deep links) onto the Bible reader's view model. The mirror image of
/// `ChatReferenceInbox` in the Chat package — that one accepts
/// references going INTO Chat; this one accepts references coming BACK
/// OUT to the Bible reader.
///
/// Owned by ``BibleApplet`` so both the inbox and the view model share
/// the applet's lifetime. The shell-side `SuperEventBus` is fire-and-
/// forget, so this subscriber being live across the whole app session
/// is what makes deep-link delivery feel guaranteed — even a tap that
/// fires while the Bible screen is unmounted lands the reader on the
/// right verses next time it appears.
@MainActor
@Observable
public final class BibleReferenceInbox {
    private let viewModel: BibleScreenViewModel
    private var subscriptionTask: Task<Void, Never>?
    /// One-shot callbacks fired after the next processed event — the
    /// `_onNextEvent` test seam. Mirrors the convention `ChatReferenceInbox`
    /// uses so a test can arm a continuation before publishing without
    /// racing the subscription task.
    private var eventCallbacks: [@MainActor () -> Void] = []

    public init(viewModel: BibleScreenViewModel) {
        self.viewModel = viewModel
    }

    // No `deinit` cancel: the inbox lives for the whole app session and
    // the subscription task holds `self` weakly so it unwinds on its own
    // if the inbox ever is released.

    /// Subscribe to `bus`. Awaiting this guarantees the subscription is
    /// registered before it returns, so an event published after the
    /// `await` is delivered. Idempotent — a second call is a no-op, so
    /// the bootstrap can call it unconditionally during composition.
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
        if case .openRecord(let reference) = event,
           let link = BibleDeepLink(reference: reference) {
            viewModel.openReference(
                bookId: link.bookId,
                chapterNumber: link.chapter,
                verseStart: link.verseStart,
                verseEnd: link.verseEnd
            )
        }
        let callbacks = eventCallbacks
        eventCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    /// Test seam: register a one-shot callback fired after the inbox
    /// processes its next bus event. Registration is synchronous so a
    /// test can arm it before publishing, with no race.
    func _onNextEvent(_ callback: @escaping @MainActor () -> Void) {
        eventCallbacks.append(callback)
    }
}
