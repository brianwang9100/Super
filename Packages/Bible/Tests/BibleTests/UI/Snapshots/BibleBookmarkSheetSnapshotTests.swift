#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleBookmarkSheet` — the 2×3 colour-slot grid presented
/// from the chapter title. Covered states:
///
/// - **empty** — all six slots free (a fresh install), light + dark
/// - **mixed** — the presented chapter holding one ribbon, two others
///   assigned elsewhere, three free; light + dark, plus a Dynamic Type XXL
///   pass (the colour names + citations reflow)
///
/// The sheet binds `AllBookmarksRequest` itself, so each render seeds an
/// in-memory database and injects it via `.databaseContext`.
@Suite("BibleBookmarkSheet snapshots")
@MainActor
struct BibleBookmarkSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("all six slots render empty in the light theme")
    func emptyLight() throws {
        try verify(seed: [], theme: .vellumLight, name: "empty_light")
    }

    @Test("all six slots render empty in the dark theme")
    func emptyDark() throws {
        try verify(seed: [], theme: .vellumDark, name: "empty_dark")
    }

    @Test("mixed assignments render in the light theme")
    func mixedLight() throws {
        try verify(seed: Self.mixedSeed, theme: .vellumLight, name: "mixed_light")
    }

    @Test("mixed assignments render in the dark theme")
    func mixedDark() throws {
        try verify(seed: Self.mixedSeed, theme: .vellumDark, name: "mixed_dark")
    }

    @Test("mixed assignments reflow at Dynamic Type XXL")
    func mixedLightXXL() throws {
        try verify(
            seed: Self.mixedSeed, theme: .vellumLight,
            dynamicType: .xxLarge, name: "mixed_light_xxl"
        )
    }

    /// Clay on the presented chapter (John 3), gold + lapis assigned
    /// elsewhere — covers the filled-current, filled-elsewhere, and empty
    /// card looks in one render.
    private static let mixedSeed: [(BibleBookmarkColor, String, Int)] = [
        (.clay, "JHN", 3),
        (.gold, "ROM", 8),
        (.lapis, "PSA", 23),
    ]

    private func verify(
        seed: [(BibleBookmarkColor, String, Int)],
        theme themeID: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) throws {
        let database = try BibleDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try database.queue.write { db in
            for (color, bookId, chapter) in seed {
                try BibleBookmarkRecord(
                    id: "bm-\(color.rawValue)", colorId: color.rawValue,
                    bookId: bookId, chapterNumber: chapter, createdAt: now
                ).insert(db)
            }
        }
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .top) {
            theme.background
            BibleBookmarkSheet(
                citation: "John 3",
                currentBookId: "JHN",
                currentChapterNumber: 3,
                onSelect: { _ in },
                onClose: {}
            )
        }
        .frame(width: 402, height: 560)
        .dynamicTypeSize(dynamicType)
        .superTheme(theme)
        .superTypography(.make(.serif))
        .databaseContext(.readOnly { database.queue })

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 560)),
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
