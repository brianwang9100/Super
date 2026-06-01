#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `AnnotationSheetContainer` — the Region that wraps the
/// stateless `AnnotationSheet` with its live `@Query` against
/// `BibleAnnotationsByTargetRequest` and the per-card mutation seams.
///
/// The wider sheet chrome is covered by `AnnotationSheetSnapshotTests`
/// (PR2, stateless input). This suite covers the *container*'s own
/// responsibilities: projecting `BibleAnnotationRecord`s into
/// `AnnotationSheet.Card`s, the text vs reference branch of
/// `makeContent(for:)`, the reference-card unparseable-body fallback,
/// the empty + generating empty states with an attached database
/// context, and the populated state across themes.
@Suite("AnnotationSheetContainer snapshots")
@MainActor
struct AnnotationSheetContainerSnapshotTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let spec = BibleAnnotationTargetSpec.verseRange(
        bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
    )

    // MARK: - Empty states

    @Test("empty container renders the empty-state copy in the light theme")
    func emptyLight() async throws {
        try await verify(seeding: [], theme: .light, name: "empty_light")
    }

    @Test("empty container with isGenerating shows the spinner-state bubble")
    func emptyGeneratingLight() async throws {
        try await verify(seeding: [], theme: .light, isGenerating: true,
                         name: "empty_generating_light")
    }

    @Test("a failed-dispatch status renders the message + retry button in light")
    func emptyFailedLight() async throws {
        try await verify(
            seeding: [],
            theme: .light,
            dispatchStatus: .failed(message: "The model didn't call bible.annotate. Try again or pick a different model."),
            name: "empty_failed_light"
        )
    }

    @Test("a failed-dispatch status renders the message + retry button in dark")
    func emptyFailedDark() async throws {
        try await verify(
            seeding: [],
            theme: .dark,
            dispatchStatus: .failed(message: "The model didn't call bible.annotate. Try again or pick a different model."),
            name: "empty_failed_dark"
        )
    }

    @Test("a failed-dispatch status renders the message + retry button in sepia")
    func emptyFailedSepia() async throws {
        try await verify(
            seeding: [],
            theme: .sepia,
            dispatchStatus: .failed(message: "The model didn't call bible.annotate. Try again or pick a different model."),
            name: "empty_failed_sepia"
        )
    }

    @Test("a failed-dispatch status reflows at Dynamic Type XXL")
    func emptyFailedLightXXL() async throws {
        try await verify(
            seeding: [],
            theme: .light,
            dispatchStatus: .failed(message: "The model didn't call bible.annotate. Try again or pick a different model."),
            dynamicType: .xxLarge,
            height: 760,
            name: "empty_failed_light_xxl"
        )
    }

    // MARK: - Populated states

    @Test("text + reference cards render in the light theme")
    func populatedLight() async throws {
        try await verify(seeding: populatedRows, theme: .light, name: "populated_light")
    }

    @Test("text + reference cards render in the dark theme")
    func populatedDark() async throws {
        try await verify(seeding: populatedRows, theme: .dark, name: "populated_dark")
    }

    @Test("text + reference cards render in the sepia theme")
    func populatedSepia() async throws {
        try await verify(seeding: populatedRows, theme: .sepia, name: "populated_sepia")
    }

    // MARK: - Regenerate-over-populated states

    @Test("a running dispatch over seeded rows hides the cards behind the generating state in light")
    func generatingOverPopulatedLight() async throws {
        try await verify(seeding: populatedRows, theme: .light, isGenerating: true,
                         name: "generating_over_populated_light")
    }

    @Test("a running dispatch over seeded rows hides the cards behind the generating state in dark")
    func generatingOverPopulatedDark() async throws {
        try await verify(seeding: populatedRows, theme: .dark, isGenerating: true,
                         name: "generating_over_populated_dark")
    }

    @Test("a running dispatch over seeded rows hides the cards behind the generating state in sepia")
    func generatingOverPopulatedSepia() async throws {
        try await verify(seeding: populatedRows, theme: .sepia, isGenerating: true,
                         name: "generating_over_populated_sepia")
    }

    @Test("the running-over-populated state reflows its label at Dynamic Type XXL")
    func generatingOverPopulatedLightXXL() async throws {
        try await verify(seeding: populatedRows, theme: .light, isGenerating: true,
                         dynamicType: .xxLarge, height: 760,
                         name: "generating_over_populated_light_xxl")
    }

    @Test("a reference card with an unparseable body renders as plain text fallback")
    func unparseableReferenceFallback() async throws {
        let rows = [
            BibleAnnotationRecord(
                id: "ref-fail", target: .verse, bookId: "ROM",
                chapterNumber: 8, verseStart: 28, verseEnd: 30,
                category: .reference, title: "Parse failed",
                body: "John 14, verse twelve",
                source: .user, modelId: "afm-3.0", createdAt: Self.now
            )
        ]
        try await verify(seeding: rows, theme: .light, name: "unparseable_reference_light")
    }

    // MARK: - Fixtures

    private var populatedRows: [BibleAnnotationRecord] {
        [
            BibleAnnotationRecord(
                id: "card-text", target: .verse, bookId: "ROM",
                chapterNumber: 8, verseStart: 28, verseEnd: 30,
                category: .summary, title: "Summary",
                body: "The golden chain of salvation: foreknown, predestined, called, justified, glorified.",
                source: .user, modelId: "afm-3.0", createdAt: Self.now
            ),
            BibleAnnotationRecord(
                id: "card-ref", target: .verse, bookId: "ROM",
                chapterNumber: 8, verseStart: 28, verseEnd: 30,
                category: .reference, title: "Cross-reference",
                body: "Ephesians 1:11",
                source: .user, modelId: "afm-3.0", createdAt: Self.now
            ),
        ]
    }

    // MARK: - Driver

    private func verify(
        seeding rows: [BibleAnnotationRecord],
        theme themeID: SuperTheme.Identifier,
        isGenerating: Bool = false,
        dispatchStatus: BibleAnnotationDispatchStatus? = nil,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat = 620,
        name: String,
        function: String = #function
    ) async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleAnnotationRepository(database: database)
        if !rows.isEmpty {
            try await repository.replace(
                target: Self.spec.target,
                bookId: Self.spec.bookId,
                chapterNumber: Self.spec.chapterNumber,
                verseStart: Self.spec.verseStart,
                verseEnd: Self.spec.verseEnd,
                inserting: rows
            )
        }

        // `isGenerating: true` legacy callers fold into the same
        // dispatchStatus parameter the container now reads — translate
        // here so the existing baselines (which were recorded with the
        // PR 3 flag) keep matching their new dispatchStatus-equivalent.
        let resolvedStatus: BibleAnnotationDispatchStatus? = {
            if let dispatchStatus { return dispatchStatus }
            if isGenerating { return .running(requestId: "snapshot-fixture") }
            return nil
        }()

        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            AnnotationSheetContainer(
                spec: Self.spec,
                citation: "Romans 8:28-30",
                catalog: .standard,
                repository: repository,
                onRegenerate: {},
                onAddAllToChat: { _ in },
                onCardAddToChat: { _ in },
                onOpenReference: { _ in },
                dispatchStatus: resolvedStatus
            )
        }
        .frame(width: 393, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)
        .databaseContext(.readOnly { database.queue })

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
