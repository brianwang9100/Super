#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("BibleBookmarkSheet snapshots", .serialized)
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

    // Cover current-chapter, other-chapter, and empty slots in one render.
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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 560)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
