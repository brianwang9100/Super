import Chat
import Core
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Owns one cached applet preview until its native outer sheet has dismissed.
@MainActor
@Observable
final class RecordPreviewPresentation {
    struct Item: Identifiable {
        let id: UUID
        let content: AnyView
    }

    enum AfterDismissal {
        case completion(RecordPreviewCompletion)
        case navigation([ShellNavigation])
    }

    private enum Phase {
        case idle
        case presenting(Item, AfterDismissal?)
        case presented(Item)
        case dismissing(Item, AfterDismissal?)
    }

    private var phase: Phase = .idle

    var isActive: Bool {
        if case .idle = phase { false } else { true }
    }

    var item: Item? {
        switch phase {
        case .presenting(let item, _), .presented(let item): item
        case .idle, .dismissing: nil
        }
    }

    /// Keeps dismissal active through `onDismiss`, including interactive dismissal.
    var binding: Binding<Item?> {
        Binding(get: { self.item }, set: { value in
            guard value == nil, let item = self.item else { return }
            self.finish(.cancel, identity: item.id)
        })
    }

    @discardableResult
    func present(reference: RecordReference, applet: any MiniApplet) -> Bool {
        guard case .idle = phase else { return false }
        let identity = UUID()
        guard let content = applet.recordPreview(for: reference, onFinish: { [weak self] completion in
            self?.finish(completion, identity: identity)
        }) else { return false }
        phase = .presenting(Item(id: identity, content: content), nil)
        return true
    }

    /// Only the first completion for this presentation can request dismissal.
    private func finish(_ completion: RecordPreviewCompletion, identity: UUID) {
        switch phase {
        case .presenting(let item, nil) where item.id == identity:
            phase = .presenting(item, .completion(completion))
        case .presented(let item) where item.id == identity:
            phase = .dismissing(item, .completion(completion))
        default: break
        }
    }

    /// Authoritative navigation invalidates any queued preview completion.
    func invalidateCompletion() {
        switch phase {
        // Preserve already queued authoritative navigation.
        case .presenting(_, .navigation), .dismissing(_, .navigation): break
        case .idle: break
        case .presenting(let item, _): phase = .presenting(item, .completion(.cancel))
        case .presented(let item), .dismissing(let item, _):
            phase = .dismissing(item, nil)
        }
    }

    /// Defers only the shell transition; the receiving applet already consumed the event.
    func deferNavigation(_ navigation: ShellNavigation) -> Bool {
        switch phase {
        case .idle: return false
        case .presenting(let item, let pending):
            phase = .presenting(item, appending(navigation, to: pending))
            return true
        case .presented(let item):
            phase = .dismissing(item, .navigation([navigation]))
            return true
        case .dismissing(let item, let pending):
            phase = .dismissing(item, appending(navigation, to: pending))
            return true
        }
    }

    private func appending(_ navigation: ShellNavigation, to pending: AfterDismissal?) -> AfterDismissal {
        if case .navigation(let actions) = pending {
            return .navigation(actions + [navigation])
        }
        return .navigation([navigation])
    }

    /// Keep the item alive until UIKit has actually presented it. Otherwise an
    /// early cancellation could clear it before mount and never receive onDismiss.
    func didPresent(identity: UUID) {
        guard case .presenting(let item, let pending) = phase, item.id == identity else { return }
        if let pending {
            phase = .dismissing(item, pending)
        } else {
            phase = .presented(item)
        }
    }

    func didDismiss() -> AfterDismissal? {
        let action: AfterDismissal?
        switch phase {
        case .dismissing(_, let pending): action = pending
        case .idle, .presenting, .presented: action = nil
        }
        phase = .idle
        return action
    }
}

enum ShellNavigation: Equatable, Sendable {
    case openConversation(id: String)
    case newConversation
    case openApplet(id: String)
    case composerAttention(ComposerAttentionRequest)
    case settings(root: SettingsSheet.Pane, pushed: SettingsSheet.Pane?)
    case sidebar
}

enum ShellRequest: Equatable, Sendable {
    case preview(RecordReference)
    case navigation(ShellNavigation)
}

#if canImport(UIKit)
/// Acknowledges the outer sheet's native presentation before early dismissal.
struct RecordPreviewPresentationObserver: UIViewControllerRepresentable {
    let identity: UUID
    let onReady: (UUID) -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        ObserverController(identity: identity, onReady: onReady)
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {}

    static func dismantleUIViewController(_ controller: ObserverController, coordinator: ()) {
        controller.onReady = nil
    }

    final class ObserverController: UIViewController {
        let identity: UUID
        var onReady: ((UUID) -> Void)?

        init(identity: UUID, onReady: @escaping (UUID) -> Void) {
            self.identity = identity
            self.onReady = onReady
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
            var presenter: UIViewController = self
            while let parent = presenter.parent { presenter = parent }
            guard presenter.presentingViewController != nil, !presenter.isBeingDismissed else { return }
            if let transition = presenter.transitionCoordinator {
                let registered = transition.animate(alongsideTransition: nil) { [weak self, weak presenter] context in
                    guard !context.isCancelled, let presenter, !presenter.isBeingDismissed else { return }
                    self?.emitReady()
                }
                // A late registration can be rejected even though native appearance completed.
                if !registered, !transition.isCancelled, !presenter.isBeingDismissed {
                    emitReady()
                }
            } else {
                emitReady()
            }
        }

        private func emitReady() {
            let callback = onReady
            onReady = nil
            callback?(identity)
        }
    }
}
#endif
