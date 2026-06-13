#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BookmarksScreen` — the sidebar applet's list of all six
/// colour slots. Covered states:
///
/// - **empty** — a fresh install: every slot a muted "Empty slot" row,
///   light + dark
/// - **populated** — three slots assigned (Clay / Gold / Lapis), the other
///   three empty, so one render locks both the filled (tappable, with
///   chevron) and empty (inert) row looks; light + dark, plus a Dynamic Type
///   XXL pass since the names + citations reflow
///
/// The screen binds `AllBookmarksRequest` itself, so each render seeds an
/// in-memory database and injects it via `.databaseContext`.
@Suite("BookmarksScreen snapshots")
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

    /// Clay → John 3, Gold → Romans 8, Lapis → Psalm 23; Moss / Plum / Slate
    /// left free so a single render covers the assigned and empty rows.
    private static let populatedSeed: [(BibleBookmarkColor, String, Int)] = [
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
        let view = BookmarksScreen()
            .frame(width: 402, height: 760)
            .dynamicTypeSize(dynamicType)
            .superTheme(theme)
            .superTypography(.make(.serif))
            .databaseContext(.readOnly { database.queue })

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
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
