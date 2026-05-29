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

    @Test("a reference card with an unparseable body renders as plain text fallback")
    func unparseableReferenceFallback() async throws {
        let rows = [
            BibleAnnotationRecord(
                id: "ref-fail", target: .verse, bookId: "ROM",
                chapterNumber: 8, verseStart: 28, verseEnd: 30,
                kind: .reference, title: "Parse failed",
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
                kind: .text, title: "Summary",
                body: "The golden chain of salvation: foreknown, predestined, called, justified, glorified.",
                source: .user, modelId: "afm-3.0", createdAt: Self.now
            ),
            BibleAnnotationRecord(
                id: "card-ref", target: .verse, bookId: "ROM",
                chapterNumber: 8, verseStart: 28, verseEnd: 30,
                kind: .reference, title: "Cross-reference",
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
                onClose: {},
                isGenerating: isGenerating
            )
        }
        .frame(width: 393, height: height)
        .superTheme(theme)
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
