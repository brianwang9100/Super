import Core
import GRDBQuery
import SwiftUI

/// Queries updates from every writer; transient generation state belongs to BibleScreen.
/// The parent supplies verse text so this container needs no loader.
struct AnnotationSheetContainer: View {
    let spec: BibleAnnotationTargetSpec
    let citation: String
    /// Captured by the parent at presentation; nil for book/chapter targets or unavailable text.
    let verseText: String?
    /// Nil makes deletion a no-op in previews/tests.
    let repository: (any BibleAnnotationRepository)?
    /// Running hides existing content; failure shows inline only when no card exists.
    /// With a retained card, onRegenerateFailed clears the failure silently.
    let dispatchStatus: BibleAnnotationDispatchStatus?
    let bottomInset: CGFloat
    let onClose: () -> Void
    let onRegenerate: () -> Void
    let onAddToChat: (BibleAnnotationRecord) -> Void
    let onOpenLink: (BibleDeepLink) -> Void
    let onRetry: () -> Void
    /// The parent surfaces deletion errors. Nil swallows them for previews/tests.
    let onDeleteFailed: ((any Error) -> Void)?
    /// Production must clear failed regeneration status while preserving the old card.
    /// Otherwise deleting that card later would reveal a stale error. Nil is for previews only.
    let onRegenerateFailed: (() -> Void)?

    @Query<BibleAnnotationsByTargetRequest> private var records: [BibleAnnotationRecord]

    init(
        spec: BibleAnnotationTargetSpec,
        citation: String,
        verseText: String?,
        repository: (any BibleAnnotationRepository)?,
        onClose: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onAddToChat: @escaping (BibleAnnotationRecord) -> Void,
        onOpenLink: @escaping (BibleDeepLink) -> Void,
        onRetry: @escaping () -> Void = {},
        onDeleteFailed: ((any Error) -> Void)? = nil,
        onRegenerateFailed: (() -> Void)? = nil,
        dispatchStatus: BibleAnnotationDispatchStatus? = nil,
        bottomInset: CGFloat = 0
    ) {
        self.spec = spec
        self.citation = citation
        self.verseText = verseText
        self.repository = repository
        self.onClose = onClose
        self.onRegenerate = onRegenerate
        self.onAddToChat = onAddToChat
        self.onOpenLink = onOpenLink
        self.onRetry = onRetry
        self.onDeleteFailed = onDeleteFailed
        self.onRegenerateFailed = onRegenerateFailed
        self.dispatchStatus = dispatchStatus
        self.bottomInset = bottomInset
        self._records = Query(constant: BibleAnnotationsByTargetRequest(spec: spec))
    }

    var body: some View {
        AnnotationSheet(
            citation: citation,
            card: card,
            onClose: onClose,
            onRegenerate: onRegenerate,
            onAddToChat: {
                guard let record = renderedRecord else { return }
                onAddToChat(record)
            },
            onDelete: {
                guard let repository else { return }
                // Empty replacement deletes the entire group atomically, including stray duplicate rows.
                let spec = spec
                Task {
                    do {
                        try await repository.replace(
                            target: spec.target,
                            bookId: spec.bookId,
                            chapterNumber: spec.chapterNumber,
                            verseStart: spec.verseStart,
                            verseEnd: spec.verseEnd,
                            inserting: []
                        )
                    } catch {
                        onDeleteFailed?(error)
                    }
                }
            },
            onOpenLink: onOpenLink,
            onRetry: onRetry,
            isGenerating: isGeneratingFromStatus,
            errorMessage: errorMessageFromStatus,
            bottomInset: bottomInset
        )
        // Check initially for reopened sheets and again when delayed query rows arrive.
        .onChange(of: hasRegenerateFailureWithCard, initial: true) { _, failed in
            if failed { onRegenerateFailed?() }
        }
    }

    private var hasRegenerateFailureWithCard: Bool {
        errorMessageFromStatus != nil && !records.isEmpty
    }

    private var isGeneratingFromStatus: Bool {
        if case .running = dispatchStatus { return true }
        return false
    }

    private var errorMessageFromStatus: String? {
        if case .failed(let message) = dispatchStatus { return message }
        return nil
    }

    // Ascending query order makes last the newest row if duplicates exist.
    private var renderedRecord: BibleAnnotationRecord? { records.last }

    private var card: AnnotationSheet.Card? {
        guard let record = renderedRecord else { return nil }
        return AnnotationSheet.Card(
            title: citation,
            verseText: verseText,
            summary: record.summary,
            provenance: makeProvenance(for: record)
        )
    }

    private func makeProvenance(for record: BibleAnnotationRecord) -> String {
        let model = record.modelId.isEmpty ? "AI" : record.modelId
        let date = Self.provenanceDateFormatter.string(from: record.createdAt)
        return "Generated by \(model) · \(date)"
    }

    private static let provenanceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Keep dates aligned with live locale changes.
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()
}
