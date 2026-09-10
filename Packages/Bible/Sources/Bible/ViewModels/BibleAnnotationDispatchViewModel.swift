import Core
import Foundation
import Observation

/// Shares one-off annotation requests across Bible readers for the applet lifetime.
@MainActor
@Observable
public final class BibleAnnotationDispatchViewModel {
    private var statusByTarget: [BibleAnnotationTargetSpec: BibleAnnotationDispatchStatus] = [:]
    private var draftsByTarget: [BibleAnnotationTargetSpec: BibleAnnotationDraft] = [:]
    private var eventBus: SuperEventBus?
    private var attachmentTask: Task<(SuperEventBus, AsyncStream<SuperEvent>), Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var pendingPublishTask: Task<Void, Never>?
    private var completionCallbacks: [@MainActor () -> Void] = []
    private var progressCallbacks: [@MainActor () -> Void] = []

    public init() {}

    /// Subscribes once to annotation progress and completion events on the shared bus.
    public func attach(to bus: SuperEventBus) async {
        guard subscriptionTask == nil else { return }
        let attachmentTask: Task<(SuperEventBus, AsyncStream<SuperEvent>), Never>
        if let pending = self.attachmentTask {
            attachmentTask = pending
        } else {
            let pending = Task { (bus, await bus.events()) }
            self.attachmentTask = pending
            attachmentTask = pending
        }
        let (attachedBus, stream) = await attachmentTask.value
        guard subscriptionTask == nil else { return }
        eventBus = attachedBus
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        self.attachmentTask = nil
    }

    public func status(for target: BibleAnnotationTargetSpec) -> BibleAnnotationDispatchStatus? {
        statusByTarget[target]
    }

    /// Retains completed text until the observing query acknowledges it.
    public func draft(for target: BibleAnnotationTargetSpec) -> BibleAnnotationDraft? {
        draftsByTarget[target]
    }

    /// Clears only a matching settled draft; a late acknowledgement cannot erase a retry.
    public func clearDraft(for target: BibleAnnotationTargetSpec, requestID: String) {
        guard draftsByTarget[target]?.requestID == requestID else { return }
        if case .running = statusByTarget[target] { return }
        draftsByTarget.removeValue(forKey: target)
        clearFailure(for: target)
    }

    public func request(
        reference: RecordReference,
        for target: BibleAnnotationTargetSpec
    ) -> BibleAnnotationDispatchResult {
        guard let eventBus else { return .unavailable }
        if case .running(let requestId) = statusByTarget[target] {
            return .alreadyRunning(requestId: requestId)
        }

        draftsByTarget[target] = BibleAnnotationDraft(requestID: reference.id)
        statusByTarget[target] = .running(requestId: reference.id)
        let previous = pendingPublishTask
        pendingPublishTask = Task {
            await previous?.value
            await eventBus.publish(.bibleAnnotateRequested(reference: reference))
        }
        return .started(requestId: reference.id)
    }

    /// Clears a terminal failure while leaving any running request intact.
    public func clearFailure(for target: BibleAnnotationTargetSpec) {
        guard case .failed = statusByTarget[target] else { return }
        statusByTarget.removeValue(forKey: target)
    }

    var statusByTargetSnapshot: [BibleAnnotationTargetSpec: BibleAnnotationDispatchStatus] {
        statusByTarget
    }

    private func handle(_ event: SuperEvent) {
        switch event {
        case .bibleAnnotateProgress(let requestId, let text):
            handleProgress(requestID: requestId, text: text)
        case .bibleAnnotateCompleted(let requestId, let result):
            handleCompletion(requestID: requestId, result: result)
        default:
            break
        }
    }

    private func runningTarget(for requestID: String) -> BibleAnnotationTargetSpec? {
        statusByTarget.first { _, status in
            if case .running(let runningRequestId) = status {
                return runningRequestId == requestID
            }
            return false
        }?.key
    }

    private func handleProgress(requestID: String, text: String) {
        if let target = runningTarget(for: requestID), draftsByTarget[target]?.requestID == requestID {
            draftsByTarget[target]?.text = text
        }
        let callbacks = progressCallbacks
        progressCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    private func handleCompletion(requestID: String, result: BibleAnnotateResult) {
        if let target = runningTarget(for: requestID) {
            switch result {
            case .success:
                draftsByTarget[target]?.isComplete = true
                statusByTarget.removeValue(forKey: target)
            case .failure(let message):
                statusByTarget[target] = .failed(message: message)
            }
        }

        let callbacks = completionCallbacks
        completionCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    func _onNextCompletionProcessed(_ callback: @escaping @MainActor () -> Void) {
        completionCallbacks.append(callback)
    }

    func _onNextProgressProcessed(_ callback: @escaping @MainActor () -> Void) {
        progressCallbacks.append(callback)
    }

    func _waitForPendingPublish() async {
        await pendingPublishTask?.value
    }
}

public enum BibleAnnotationDispatchResult: Sendable, Equatable {
    case started(requestId: String)
    case alreadyRunning(requestId: String)
    case unavailable
}
