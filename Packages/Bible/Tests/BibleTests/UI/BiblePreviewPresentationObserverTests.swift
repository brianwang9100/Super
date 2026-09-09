#if canImport(UIKit)
import Core
import Testing
import UIKit
@testable import Bible

@Suite("Bible preview presentation observer", .serialized)
@MainActor
struct BiblePreviewPresentationObserverTests {
    @Test("rejected registration makes the appeared preview ready without a completion callback")
    func rejectedRegistration() {
        let reader = BibleScreenViewModel(textLoader: DatabaseBibleTextLoader())
            .makePreviewReader(for: BibleDeepLink(bookId: "ROM", chapter: 8, verseStart: 28, verseEnd: 30))
        let preview = BibleChapterPreviewViewModel(reader: reader, onFinish: { _ in })
        let coordinator = ControlledTransitionCoordinator(acceptsRegistration: false)
        let parent = ModalContainer(coordinator: coordinator)
        var identities: [UUID] = []
        let observer = makeObserver(parent: parent, identity: preview.identity) { identity in
            identities.append(identity)
            preview.presentationDidComplete(identity: identity)
        }

        appear(observer)

        #expect(preview.isReady)
        #expect(reader.isActionSheetPresented)
        #expect(identities == [preview.identity])
        // UIKit may still invoke completion even when registration returned false.
        reader.dismissActionSheet()
        coordinator.complete()
        appear(observer)
        #expect(identities == [preview.identity])
        #expect(!reader.isActionSheetPresented)
    }

    @Test("accepted registration waits for successful native completion")
    func acceptedRegistration() {
        let coordinator = ControlledTransitionCoordinator(acceptsRegistration: true)
        let parent = ModalContainer(coordinator: coordinator)
        var identities: [UUID] = []
        let identity = UUID()
        let observer = makeObserver(parent: parent, identity: identity) { identities.append($0) }
        appear(observer)
        #expect(identities.isEmpty)
        coordinator.complete()
        coordinator.complete()
        appear(observer)
        #expect(identities == [identity])
    }

    @Test("cancelled native transitions never emit readiness", arguments: [false, true])
    func cancelledTransition(acceptsRegistration: Bool) {
        let coordinator = ControlledTransitionCoordinator(acceptsRegistration: acceptsRegistration)
        coordinator.isCancelled = true
        let parent = ModalContainer(coordinator: coordinator)
        var identities: [UUID] = []
        let observer = makeObserver(parent: parent) { identities.append($0) }
        appear(observer)
        coordinator.complete()
        #expect(identities.isEmpty)
    }

    @Test("dismissal beginning during registration suppresses readiness", arguments: [false, true])
    func dismissalDuringRegistration(acceptsRegistration: Bool) {
        let coordinator = ControlledTransitionCoordinator(acceptsRegistration: acceptsRegistration)
        let parent = ModalContainer(coordinator: coordinator)
        coordinator.onRegister = { [weak parent] in parent?.dismissing = true }
        var identities: [UUID] = []
        let observer = makeObserver(parent: parent) { identities.append($0) }
        appear(observer)
        coordinator.complete()
        #expect(identities.isEmpty)
    }

    @Test("unmount invalidation suppresses retained completion and future appearances")
    func invalidation() {
        let coordinator = ControlledTransitionCoordinator(acceptsRegistration: true)
        let parent = ModalContainer(coordinator: coordinator)
        var identities: [UUID] = []
        var unmounts = 0
        let observer = BiblePreviewPresentationObserver.ObserverController(
            identity: UUID(), onReady: { identities.append($0) }, onUnmount: { unmounts += 1 }
        )
        parent.addChild(observer)
        observer.didMove(toParent: parent)
        appear(observer)
        observer.invalidate()
        observer.invalidate()
        coordinator.complete()
        appear(observer)
        #expect(identities.isEmpty)
        #expect(unmounts == 1)
    }

    @Test("standalone hosts and dismissing modals cannot claim readiness", arguments: [false, true])
    func unavailableModal(dismissing: Bool) {
        let parent = ModalContainer(coordinator: nil)
        parent.dismissing = dismissing
        if !dismissing { parent.modalSource = nil }
        var identities: [UUID] = []
        let observer = makeObserver(parent: parent) { identities.append($0) }
        appear(observer)
        #expect(identities.isEmpty)
    }

    @Test("an appeared modal without a coordinator is ready exactly once")
    func noCoordinator() {
        let parent = ModalContainer(coordinator: nil)
        var identities: [UUID] = []
        let identity = UUID()
        let observer = makeObserver(parent: parent, identity: identity) { identities.append($0) }
        appear(observer)
        appear(observer)
        #expect(identities == [identity])
    }

    private func appear(_ observer: UIViewController) {
        observer.beginAppearanceTransition(true, animated: false)
        observer.endAppearanceTransition()
    }

    private func makeObserver(
        parent: ModalContainer,
        identity: UUID = UUID(),
        onReady: @escaping (UUID) -> Void
    ) -> BiblePreviewPresentationObserver.ObserverController {
        let observer = BiblePreviewPresentationObserver.ObserverController(identity: identity, onReady: onReady, onUnmount: {})
        parent.addChild(observer)
        observer.didMove(toParent: parent)
        return observer
    }
}

@MainActor
private final class ModalContainer: UIViewController {
    var modalSource: UIViewController? = UIViewController()
    var dismissing = false
    private let coordinator: ControlledTransitionCoordinator?

    init(coordinator: ControlledTransitionCoordinator?) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var presentingViewController: UIViewController? { modalSource }
    override var isBeingDismissed: Bool { dismissing }
    override var transitionCoordinator: (any UIViewControllerTransitionCoordinator)? { coordinator }
}

@MainActor
private final class ControlledTransitionCoordinator: NSObject, UIViewControllerTransitionCoordinator {
    typealias Completion = (any UIViewControllerTransitionCoordinatorContext) -> Void

    let acceptsRegistration: Bool
    var onRegister: (() -> Void)?
    private var completion: Completion?

    init(acceptsRegistration: Bool) { self.acceptsRegistration = acceptsRegistration }

    func animate(alongsideTransition animation: Completion?, completion: Completion?) -> Bool {
        self.completion = completion
        onRegister?()
        return acceptsRegistration
    }

    func complete() { completion?(self) }

    func animateAlongsideTransition(in view: UIView?, animation: Completion?, completion: Completion?) -> Bool {
        animate(alongsideTransition: animation, completion: completion)
    }

    func notifyWhenInteractionChanges(_ handler: @escaping Completion) {}
    func notifyWhenInteractionEnds(_ handler: @escaping Completion) {}

    let isAnimated = true
    let presentationStyle: UIModalPresentationStyle = .pageSheet
    let initiallyInteractive = false
    let isInterruptible = false
    let isInteractive = false
    var isCancelled = false
    let transitionDuration: TimeInterval = 0.25
    let percentComplete: CGFloat = 1
    let completionVelocity: CGFloat = 1
    let completionCurve: UIView.AnimationCurve = .easeInOut
    let containerView = UIView()
    let targetTransform = CGAffineTransform.identity

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }
}
#endif
