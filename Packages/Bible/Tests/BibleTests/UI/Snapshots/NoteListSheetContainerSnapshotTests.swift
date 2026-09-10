#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Covers database-backed projection; NoteListSheetSnapshotTests owns sheet chrome.
/// The nested autoCompose sheet is absent from fixed-layout captures: editor content
/// and view-model flags have separate coverage, but the one-shot latch needs manual verification.
@Suite("NoteListSheetContainer snapshots", .serialized)
@MainActor
struct NoteListSheetContainerSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let spec = BibleNoteTargetSpec.verseRange(
        bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 18
    )

    // MARK: - Empty state

    @Test("empty container renders the hero in the light theme")
    func emptyLight() async throws {
        try await verify(seeding: [], theme: .vellumLight, name: "empty_light")
    }

    @Test("empty container renders the hero in the dark theme")
    func emptyDark() async throws {
        try await verify(seeding: [], theme: .vellumDark, name: "empty_dark")
    }

    // MARK: - Populated states (user + assistant provenance)

    @Test("user and assistant notes render with the right footers in the light theme")
    func populatedLight() async throws {
        try await verify(seeding: populatedRows, theme: .vellumLight, name: "populated_light")
    }

    @Test("user and assistant notes render with the right footers in the dark theme")
    func populatedDark() async throws {
        try await verify(seeding: populatedRows, theme: .vellumDark, name: "populated_dark")
    }

    @Test("populated notes reflow at Dynamic Type XXL")
    func populatedLightXXL() async throws {
        try await verify(seeding: populatedRows, theme: .vellumLight, dynamicType: .xxLarge,
                         height: 760, name: "populated_light_xxl")
    }

    // MARK: - Fixtures

    private var populatedRows: [BibleNoteRecord] {
        [
            BibleNoteRecord(
                id: "assistant", target: .verse, bookId: "JHN", chapterNumber: 3,
                verseStart: 16, verseEnd: 18,
                body: "monogenēs — \"one of a kind,\" not \"only-begotten\" biologically. v17 balances v16.",
                source: .assistant, modelId: "Claude",
                createdAt: Self.now.addingTimeInterval(60), updatedAt: Self.now.addingTimeInterval(60)
            ),
            BibleNoteRecord(
                id: "user", target: .verse, bookId: "JHN", chapterNumber: 3,
                verseStart: 16, verseEnd: 18,
                body: "The hinge of the whole gospel. Come back here when belief feels like effort.",
                source: .user, modelId: nil,
                createdAt: Self.now, updatedAt: Self.now
            ),
        ]
    }

    // MARK: - Driver

    private func verify(
        seeding rows: [BibleNoteRecord],
        theme themeID: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat = 620,
        name: String,
        function: String = #function
    ) async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleNoteRepository(database: database)
        for row in rows {
            try await repository.insert(row)
        }

        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            NoteListSheetContainer(
                spec: Self.spec,
                citation: "John 3:16-18",
                onClose: {},
                onCreate: { _ in },
                onUpdate: { _, _ in },
                onDelete: { _ in }
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
