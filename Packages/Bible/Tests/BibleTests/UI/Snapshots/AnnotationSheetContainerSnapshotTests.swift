#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Covers database-backed projection; AnnotationSheetSnapshotTests covers stateless sheet chrome.
@Suite("AnnotationSheetContainer snapshots", .serialized)
@MainActor
struct AnnotationSheetContainerSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let spec = BibleAnnotationTargetSpec.verseRange(
        bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
    )
    private static let verseText = """
    We know that all things work together for good for those who love \
    God, for those who are called according to his purpose.
    """

    // MARK: - Empty states

    @Test("empty container renders the empty-state copy in the light theme")
    func emptyLight() async throws {
        try await verify(seeding: [], theme: .vellumLight, name: "empty_light")
    }

    @Test("empty container with a running dispatch shows the spinner-state bubble")
    func emptyGeneratingLight() async throws {
        try await verify(seeding: [], theme: .vellumLight, isGenerating: true,
                         name: "empty_generating_light")
    }

    @Test("a failed-dispatch status renders the message + retry button in light")
    func emptyFailedLight() async throws {
        try await verify(
            seeding: [],
            theme: .vellumLight,
            dispatchStatus: .failed(message: "The model didn't call bible.annotate. Try again or pick a different model."),
            name: "empty_failed_light"
        )
    }

    @Test("a failed-dispatch status renders the message + retry button in dark")
    func emptyFailedDark() async throws {
        try await verify(
            seeding: [],
            theme: .vellumDark,
            dispatchStatus: .failed(message: "The model didn't call bible.annotate. Try again or pick a different model."),
            name: "empty_failed_dark"
        )
    }

    @Test("a failed-dispatch status reflows at Dynamic Type XXL")
    func emptyFailedLightXXL() async throws {
        try await verify(
            seeding: [],
            theme: .vellumLight,
            dispatchStatus: .failed(message: "The model didn't call bible.annotate. Try again or pick a different model."),
            dynamicType: .xxLarge,
            height: 760,
            name: "empty_failed_light_xxl"
        )
    }

    // MARK: - Populated states

    @Test("a seeded summary row projects into the single card in the light theme")
    func populatedLight() async throws {
        try await verify(seeding: populatedRows, theme: .vellumLight, name: "populated_light")
    }

    @Test("a seeded summary row projects into the single card in the dark theme")
    func populatedDark() async throws {
        try await verify(seeding: populatedRows, theme: .vellumDark, name: "populated_dark")
    }

    // MARK: - Regenerate-over-populated states

    @Test("a running dispatch over a seeded row hides the card behind the generating state in light")
    func generatingOverPopulatedLight() async throws {
        try await verify(seeding: populatedRows, theme: .vellumLight, isGenerating: true,
                         name: "generating_over_populated_light")
    }

    @Test("a running dispatch over a seeded row hides the card behind the generating state in dark")
    func generatingOverPopulatedDark() async throws {
        try await verify(seeding: populatedRows, theme: .vellumDark, isGenerating: true,
                         name: "generating_over_populated_dark")
    }

    @Test("the running-over-populated state reflows its label at Dynamic Type XXL")
    func generatingOverPopulatedLightXXL() async throws {
        try await verify(seeding: populatedRows, theme: .vellumLight, isGenerating: true,
                         dynamicType: .xxLarge, height: 760,
                         name: "generating_over_populated_light_xxl")
    }

    // MARK: - Fixtures

    private var populatedRows: [BibleAnnotationRecord] {
        [
            BibleAnnotationRecord(
                id: "row-1", target: .verse, bookId: "ROM",
                chapterNumber: 8, verseStart: 28, verseEnd: 30,
                summary: """
                ### Plain meaning
                Nothing — pain, loss, even death — falls outside what \
                God can weave toward the believer's good. **"Good"** \
                means conformity to Christ, not pleasant circumstances.

                ### Context
                "All things" includes the suffering Paul names earlier \
                in the chapter — creation's groaning, the believer's \
                weakness in prayer, even persecution.
                """,
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
                verseText: Self.verseText,
                repository: repository,
                onClose: {},
                onRegenerate: {},
                onAddToChat: { _ in },
                onOpenLink: { _ in },
                dispatchStatus: resolvedStatus
            )
        }
        .frame(width: 393, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)
        .databaseContext(.readOnly { database.queue })

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
