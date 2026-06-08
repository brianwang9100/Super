#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of `ChatsScreen` across themes (light/dark/sepia),
/// the Dynamic Type XXL and xSmall variants, the populated list with
/// relative-time subtitles, and the two search-active states (matches +
/// no matches). The xSmall variant guards the title/subtitle hierarchy at
/// the small end of the range, where their sizes converge and weight +
/// color must carry the distinction.
///
/// Conversation fixtures span the relative-time buckets the design calls
/// out — "just now" through "3 mo ago" — so the rows exercise every
/// branch of `RelativeTimeFormatter.format`.
@Suite("ChatsScreen snapshots", .serialized)
@MainActor
struct ChatsScreenSnapshotTests {
    private static let frame = CGSize(width: 402, height: 874)
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    init() { SnapshotFontRegistration.ensureRegistered() }

    /// Conversations spanning every relative-time bucket. Titles are
    /// recognizable English phrases (not lorem ipsum) so search-active
    /// variants can target a stable substring.
    private static let sampleConversations: [ConversationRecord] = [
        .init(id: "c-just",      title: "Italy trip planning",                          createdAt: now, updatedAt: now.addingTimeInterval(-30)),
        .init(id: "c-min",       title: "Quick stir-fried snow pea leaves",             createdAt: now, updatedAt: now.addingTimeInterval(-12 * 60)),
        .init(id: "c-hr",        title: "Salomon stability hiking shoes",               createdAt: now, updatedAt: now.addingTimeInterval(-3 * 3600)),
        .init(id: "c-yest",      title: "Building a local chat app with tool calling",  createdAt: now, updatedAt: now.addingTimeInterval(-30 * 3600)),
        .init(id: "c-days",      title: "Newborn sleep schedule, weeks 4-8",            createdAt: now, updatedAt: now.addingTimeInterval(-3 * 86_400)),
        .init(id: "c-lastweek",  title: "Substituting crushed tomatoes in sugo",        createdAt: now, updatedAt: now.addingTimeInterval(-9 * 86_400)),
        .init(id: "c-weeks",     title: "Why the sky is blue",                          createdAt: now, updatedAt: now.addingTimeInterval(-20 * 86_400)),
        .init(id: "c-mo1",       title: "MacBook Pro charitable donation options",      createdAt: now, updatedAt: now.addingTimeInterval(-45 * 86_400)),
        .init(id: "c-mo3",       title: "Little Gem salad dressing with anchovy",       createdAt: now, updatedAt: now.addingTimeInterval(-95 * 86_400)),
    ]

    @Test("populated, light")
    func populatedLight() async throws {
        try await verify(theme: .vellumLight, name: "chats_populated_light")
    }

    @Test("populated, dark")
    func populatedDark() async throws {
        try await verify(theme: .vellumDark, name: "chats_populated_dark")
    }

    @Test("populated, large font scale")
    func populatedLargeFontScale() async throws {
        try await verify(
            theme: .vellumLight,
            fontScale: 1.5,
            dynamicType: .accessibility3,
            name: "chats_populated_light_xxl"
        )
    }

    @Test("populated, xSmall Dynamic Type")
    func populatedXSmallDynamicType() async throws {
        // At xSmall Dynamic Type the title and subtitle sizes converge, so
        // this baseline guards that weight (.medium) and color (ink vs
        // inkFaint) keep the two lines distinguishable.
        try await verify(
            theme: .vellumLight,
            dynamicType: .xSmall,
            name: "chats_populated_light_xsmall"
        )
    }

    @Test("search active with matches")
    func searchActiveWithMatches() async throws {
        // "snow" matches "Quick stir-fried snow pea leaves" only — one
        // result, so the result-count line should render in the singular
        // ("1 match").
        try await verify(
            theme: .vellumLight,
            initialSearchText: "snow",
            name: "chats_search_matches_light"
        )
    }

    @Test("search active with no matches")
    func searchActiveNoMatches() async throws {
        // "zzz" matches none of the fixture titles, so the screen falls
        // back to the italic-serif "No matches." empty state with the
        // quoted-query caption.
        try await verify(
            theme: .vellumLight,
            initialSearchText: "zzz",
            name: "chats_search_no_matches_light"
        )
    }

    @Test("no chats yet")
    func noChatsYet() async throws {
        // Database is empty — the screen should render the
        // first-launch empty state ("No chats" + "Tap + button to start
        // new chat"). The `seedConversations: false` flag tells the
        // helper to skip the fixture insert so `@Query` resolves to
        // zero rows.
        try await verify(
            theme: .vellumLight,
            seedConversations: false,
            name: "chats_empty_light"
        )
    }

    private func verify(
        theme: SuperTheme.Identifier,
        fontScale: CGFloat = 1,
        dynamicType: DynamicTypeSize = .large,
        initialSearchText: String = "",
        seedConversations: Bool = true,
        name: String,
        function: String = #function
    ) async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBConversationRepository(database: database)
        if seedConversations {
            for record in Self.sampleConversations {
                try await repository.save(record)
            }
        }

        let view = ChatsScreen(initialSearchText: initialSearchText, now: Self.now)
            .databaseContext(.readOnly { database.queue })
            .frame(width: Self.frame.width, height: Self.frame.height)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
            .superFontScale(fontScale)
            .superTypography(.make(.serif, fontScale: fontScale))
            .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
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
