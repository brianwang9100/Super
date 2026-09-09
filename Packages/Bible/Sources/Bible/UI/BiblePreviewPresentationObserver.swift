import SwiftUI

#if canImport(UIKit)
import UIKit

/// Observes UIKit's completed modal appearance, never SwiftUI mount timing.
struct BiblePreviewPresentationObserver: UIViewControllerRepresentable {
    let identity: UUID
    let onReady: (UUID) -> Void
    let onUnmount: () -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        ObserverController(identity: identity, onReady: onReady, onUnmount: onUnmount)
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {}

    static func dismantleUIViewController(_ controller: ObserverController, coordinator: ()) {
        controller.invalidate()
    }

    final class ObserverController: UIViewController {
        private let identity: UUID
        private var onReady: ((UUID) -> Void)?
        private var onUnmount: (() -> Void)?

        init(identity: UUID, onReady: @escaping (UUID) -> Void, onUnmount: @escaping () -> Void) {
            self.identity = identity
            self.onReady = onReady
            self.onUnmount = onUnmount
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // A standalone snapshot/host has no native modal ancestor and
            // cannot claim that a chapter sheet has finished presenting.
            var presenter: UIViewController = self
            while let parent = presenter.parent { presenter = parent }
            guard presenter.presentingViewController != nil, !presenter.isBeingDismissed else { return }
            if let transition = presenter.transitionCoordinator {
                let registered = transition.animate(alongsideTransition: nil) { [weak self, weak presenter] context in
                    guard !context.isCancelled, let presenter, !presenter.isBeingDismissed else { return }
                    self?.emitReady()
                }
                // UIKit may reject registration after native appearance. It may
                // still call completion later; emitReady consumes its callback once.
                if !registered, !transition.isCancelled, !presenter.isBeingDismissed {
                    emitReady()
                }
            } else {
                emitReady()
            }
        }

        private func emitReady() {
            guard let callback = onReady else { return }
            onReady = nil
            callback(identity)
        }

        func invalidate() {
            onReady = nil
            let callback = onUnmount
            onUnmount = nil
            callback?()
        }
    }
}
#else
/// Non-UIKit hosts do not synthesize a native iOS presentation-completion signal.
struct BiblePreviewPresentationObserver: View {
    let identity: UUID
    let onReady: (UUID) -> Void
    let onUnmount: () -> Void

    var body: some View { Color.clear.onDisappear(perform: onUnmount) }
}
#endif
