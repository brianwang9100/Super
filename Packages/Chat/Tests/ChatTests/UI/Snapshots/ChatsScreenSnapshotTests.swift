#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("ChatsScreen snapshots", .serialized)
@MainActor
struct ChatsScreenSnapshotTests {
    private static let frame = CGSize(width: 402, height: 874)
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    init() { SnapshotFontRegistration.ensureRegistered() }

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
        // At xSmall, title/subtitle sizes converge; weight and color must preserve hierarchy.
        try await verify(
            theme: .vellumLight,
            dynamicType: .xSmall,
            name: "chats_populated_light_xsmall"
        )
    }

    @Test("search active with matches")
    func searchActiveWithMatches() async throws {
        try await verify(
            theme: .vellumLight,
            initialSearchText: "snow",
            name: "chats_search_matches_light"
        )
    }

    @Test("search active with no matches")
    func searchActiveNoMatches() async throws {
        try await verify(
            theme: .vellumLight,
            initialSearchText: "zzz",
            name: "chats_search_no_matches_light"
        )
    }

    @Test("no chats yet")
    func noChatsYet() async throws {
        try await verify(
            theme: .vellumLight,
            seedConversations: false,
            name: "chats_empty_light"
        )
    }

    @Test("search and conversation rows share a bounded wide column")
    func landscape() async throws {
        try await verify(theme: .vellumLight, size: CGSize(width: 1024, height: 768), name: "landscape")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        fontScale: CGFloat = 1,
        dynamicType: DynamicTypeSize = .large,
        initialSearchText: String = "",
        seedConversations: Bool = true,
        size: CGSize = Self.frame,
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
            .frame(width: size.width, height: size.height)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
            .superFontScale(fontScale)
            .superTypography(.make(.serif, fontScale: fontScale))
            .dynamicTypeSize(dynamicType)

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
