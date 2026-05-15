#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleScreen` — the M1 chapter reader.
///
/// The populated state renders the real bundled 1 Peter 2 (prose + poetry
/// paragraphs both fall within the captured frame) across the three themes
/// at default and XXL Dynamic Type, per root `AGENTS.md` §Testing. The empty
/// state covers the "chapter unavailable" fallback in light and dark.
@Suite("BibleScreen snapshots")
@MainActor
struct BibleScreenSnapshotTests {
    @Test("1 Peter 2 renders in the light theme")
    func populatedLight() throws {
        try verify(peter2(), theme: .light, name: "populated_light")
    }

    @Test("1 Peter 2 renders in the dark theme")
    func populatedDark() throws {
        try verify(peter2(), theme: .dark, name: "populated_dark")
    }

    @Test("1 Peter 2 renders in the sepia theme")
    func populatedSepia() throws {
        try verify(peter2(), theme: .sepia, name: "populated_sepia")
    }

    @Test("1 Peter 2 renders in the light theme at Dynamic Type XXL")
    func populatedLightXXL() throws {
        try verify(peter2(), theme: .light, dynamicType: .xxLarge, name: "populated_light_xxl")
    }

    @Test("1 Peter 2 renders in the dark theme at Dynamic Type XXL")
    func populatedDarkXXL() throws {
        try verify(peter2(), theme: .dark, dynamicType: .xxLarge, name: "populated_dark_xxl")
    }

    @Test("1 Peter 2 renders in the sepia theme at Dynamic Type XXL")
    func populatedSepiaXXL() throws {
        try verify(peter2(), theme: .sepia, dynamicType: .xxLarge, name: "populated_sepia_xxl")
    }

    @Test("the unavailable state renders in the light theme")
    func emptyLight() {
        verify(BibleScreen(bookName: "Bible", chapter: nil), theme: .light, name: "empty_light")
    }

    @Test("the unavailable state renders in the dark theme")
    func emptyDark() {
        verify(BibleScreen(bookName: "Bible", chapter: nil), theme: .dark, name: "empty_dark")
    }

    /// Builds a `BibleScreen` over the real bundled 1 Peter 2.
    private func peter2() throws -> BibleScreen {
        let chapter = try #require(
            try BundledBibleTextLoader().loadBook(id: "1PE").chapter(2)
        )
        return BibleScreen(bookName: "1 Peter", chapter: chapter)
    }

    private func verify(
        _ screen: BibleScreen,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let view = screen
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .frame(width: 402, height: 760)

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
