public enum RecordPreviewCompletion: Sendable, Equatable {
    case cancel
    case openRecord(reference: RecordReference)
    case addToChat(reference: RecordReference, startNewConversation: Bool)
}
