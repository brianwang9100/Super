/// Pure projection of persisted rows and request-scoped transient annotation state.
struct AnnotationPresentation: Equatable {
    let text: String
    let savedRecord: BibleAnnotationRecord?
    let isWorking: Bool
    let treatAsPartial: Bool
    let errorMessage: String?
    let isShowingDraft: Bool
    let canReturnToSaved: Bool
    let acknowledgedRequestID: String?

    init(
        snapshot: AnnotationSheetSnapshot?,
        draft: BibleAnnotationDraft?,
        dispatchStatus: BibleAnnotationDispatchStatus?
    ) {
        savedRecord = snapshot?.records.last
        if case .running = dispatchStatus {
            isWorking = true
        } else {
            isWorking = false
        }
        if case .failed(let message) = dispatchStatus {
            errorMessage = message
        } else {
            errorMessage = nil
        }

        // A query created with the completed request's token starts only after
        // the write succeeded. Its first result is authoritative, even empty
        // or externally replaced; earlier query emissions cannot prove this.
        if let draft, draft.isComplete,
           snapshot?.completedRequestID == draft.requestID {
            acknowledgedRequestID = draft.requestID
        } else {
            acknowledgedRequestID = nil
        }
        isShowingDraft = acknowledgedRequestID == nil && (draft != nil || isWorking)
        if isShowingDraft {
            text = draft?.text ?? ""
            treatAsPartial = draft?.isComplete != true
        } else {
            text = savedRecord?.summary ?? ""
            treatAsPartial = false
        }
        canReturnToSaved = isShowingDraft && !isWorking && errorMessage != nil && savedRecord != nil
    }
}
