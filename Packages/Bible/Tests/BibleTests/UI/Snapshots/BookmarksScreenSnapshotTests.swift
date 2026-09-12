#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("BookmarksScreen snapshots", .serialized)
@MainActor
struct BookmarksScreenSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("all six slots render empty in the light theme")
    func emptyLight() throws {
        try verify(seed: [], theme: .vellumLight, name: "empty_light")
    }

    @Test("all six slots render empty in the dark theme")
    func emptyDark() throws {
        try verify(seed: [], theme: .vellumDark, name: "empty_dark")
    }

    @Test("assigned + empty slots render in the light theme")
    func populatedLight() throws {
        try verify(seed: Self.populatedSeed, theme: .vellumLight, name: "populated_light")
    }

    @Test("assigned + empty slots render in the dark theme")
    func populatedDark() throws {
        try verify(seed: Self.populatedSeed, theme: .vellumDark, name: "populated_dark")
    }

    @Test("assigned + empty slots reflow at Dynamic Type XXL")
    func populatedLightXXL() throws {
        try verify(
            seed: Self.populatedSeed, theme: .vellumLight,
            dynamicType: .xxLarge, name: "populated_light_xxl"
        )
    }

    @Test("bookmark slots stay grouped in a wide window")
    func landscape() throws {
        try verify(seed: Self.populatedSeed, theme: .vellumLight,
                   size: CGSize(width: 1024, height: 768), name: "landscape")
    }

    // Assigned and empty slots share one capture.
    private static let populatedSeed: [(BibleBookmarkColor, String, Int)] = [
        (.clay, "JHN", 3),
        (.gold, "ROM", 8),
        (.lapis, "PSA", 23),
    ]

    private func verify(
        seed: [(BibleBookmarkColor, String, Int)],
        theme themeID: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        size: CGSize = CGSize(width: 402, height: 760),
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
        let view = BookmarksScreen()
            .frame(width: size.width, height: size.height)
            .dynamicTypeSize(dynamicType)
            .superTheme(theme)
            .superTypography(.make(.serif))
            .databaseContext(.readOnly { database.queue })

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: size.width, height: size.height)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
