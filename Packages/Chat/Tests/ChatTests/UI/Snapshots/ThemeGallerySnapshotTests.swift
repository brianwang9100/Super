#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// The single place all eight theme variants (four families × light/dark) are
/// pixel-locked on a representative chat surface. The per-screen suites render
/// only Vellum light/dark (the default) to keep CI cost flat; this gallery is
/// where Sepia / Scriptorium / Slate — and Vellum again — get their palette
/// coverage, so a regression in any family's tokens fails here. The fixture
/// exercises the user bubble (Geist), assistant prose (EB Garamond, with
/// strong/emphasis), inline code (mono), and a tool-call card so accent / ink /
/// border / code tokens are all on screen.
@Suite("Theme gallery — chat", .serialized)
@MainActor
struct ThemeGallerySnapshotTests {
    /// Register Core's bundled brand fonts before any render so the suite is
    /// order-independent in the shared test process (see SnapshotFontRegistration).
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let items: [MessageList.Item] = [
        .userBubble(id: "u1", text: "Which theme replaces the green one?", references: []),
        .assistantText(
            id: "a1",
            thinking: nil,
            thinkingDurationMs: nil,
            text: "**Scriptorium** does — a muted moss-olive, *the green taken to seminary*. "
                + "Inline `code` stays monospaced.",
            toolCalls: [
                .init(
                    id: "t1",
                    toolName: "time.now",
                    toolDisplayName: "Current time",
                    parametersJSON: "{\"timezone\":\"Europe/Lisbon\"}",
                    resultText: "Current time: Monday, June 8, 2026 at 4:53:00 PM WEST",
                    status: .success
                )
            ],
            sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
        ),
    ]

    @Test("a populated transcript renders in every theme variant",
          arguments: SuperTheme.Identifier.allCases)
    func gallery(_ id: SuperTheme.Identifier) {
        let view = MessageList(items: items, verbosity: .verbose)
            .superTheme(.make(id))
            .frame(width: 402, height: 560)
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 560)),
            named: "gallery_chat_\(id.rawValue)",
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: #function
        )
        if let failure {
            Issue.record("gallery_chat_\(id.rawValue): \(failure)")
        }
    }
}
#endif
