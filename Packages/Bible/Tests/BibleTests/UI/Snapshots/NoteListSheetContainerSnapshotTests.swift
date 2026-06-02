#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `NoteListSheetContainer` — the Region that wraps the stateless
/// `NoteListSheet` with its live `@Query` against `NotesForRangeRequest`.
///
/// The sheet chrome itself is covered by `NoteListSheetSnapshotTests` (PR2,
/// stateless input). This suite covers the *container*'s own responsibilities:
/// projecting `BibleNoteRecord`s into `NoteListSheet.Item`s, the
/// `author(for:)` provenance derivation (user → no footer; assistant →
/// `modelId`, falling back to `"AI"`), and the empty vs populated list driven
/// by the real `@Query` with an attached database context.
///
/// The `autoCompose` editor-presentation path is *not* snapshotted: it opens a
/// nested `.sheet`, which a fixed-layout host doesn't render into the captured
/// image. The editor itself is covered in isolation by `NoteEditorSnapshotTests`,
/// and the view model's `autoCompose` flag is unit-covered in
/// `BibleScreenViewModelNotesTests`; the container's one-shot `didAutoCompose`
/// latch is left to manual verification per CLAUDE.md §3.
@Suite("NoteListSheetContainer snapshots")
@MainActor
struct NoteListSheetContainerSnapshotTests {
    /// Register Core's bundled brand fonts so the migrated JetBrains Mono /
    /// Instrument Serif chrome faces resolve instead of baking the system
    /// fallback, and so this suite stays order-independent (registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let spec = BibleNoteTargetSpec.verseRange(
        bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 18
    )

    // MARK: - Empty state

    @Test("empty container renders the hero in the light theme")
    func emptyLight() async throws {
        try await verify(seeding: [], theme: .light, name: "empty_light")
    }

    @Test("empty container renders the hero in the dark theme")
    func emptyDark() async throws {
        try await verify(seeding: [], theme: .dark, name: "empty_dark")
    }

    @Test("empty container renders the hero in the sepia theme")
    func emptySepia() async throws {
        try await verify(seeding: [], theme: .sepia, name: "empty_sepia")
    }

    // MARK: - Populated states (user + assistant provenance)

    @Test("user and assistant notes render with the right footers in the light theme")
    func populatedLight() async throws {
        try await verify(seeding: populatedRows, theme: .light, name: "populated_light")
    }

    @Test("user and assistant notes render with the right footers in the dark theme")
    func populatedDark() async throws {
        try await verify(seeding: populatedRows, theme: .dark, name: "populated_dark")
    }

    @Test("user and assistant notes render with the right footers in the sepia theme")
    func populatedSepia() async throws {
        try await verify(seeding: populatedRows, theme: .sepia, name: "populated_sepia")
    }

    @Test("populated notes reflow at Dynamic Type XXL")
    func populatedLightXXL() async throws {
        try await verify(seeding: populatedRows, theme: .light, dynamicType: .xxLarge,
                         height: 760, name: "populated_light_xxl")
    }

    // MARK: - Fixtures

    /// One assistant note (provenance footer) and one user note (no footer),
    /// newest-first like the request's ordering. The assistant row carries a
    /// `modelId` so the footer reads "Written by Claude".
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
                onCreate: { _ in },
                onUpdate: { _, _ in },
                onDelete: { _ in }
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
