#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of `SettingsMemoryPane` — the per-tool config
/// pane reached from the gear affordance on the Memory row.
///
/// Three core states (empty, populated light, populated dark) plus a
/// Dynamic Type XXL variant on the populated case so the inline-edit
/// hit area survives the largest accessibility size. All scenarios
/// wire a fully-migrated in-memory `ChatDatabase` so the pane's
/// `@Query` resolves through the real `MemoriesRequest` — recording
/// against the request's `defaultValue` would mask binding regressions.
@Suite("SettingsMemoryPane snapshots", .serialized)
@MainActor
struct SettingsMemoryPaneSnapshotTests {
    private static let frame = CGSize(width: 402, height: 874)
    private static let appInfo = SuperAppInfo(bundleName: "Super", version: "0.3.1", build: "1")

    @Test("empty state in light")
    func emptyLight() async throws {
        try await verify(theme: .light, memories: [], name: "settings_memory_empty_light")
    }

    @Test("populated in light")
    func populatedLight() async throws {
        try await verify(
            theme: .light,
            memories: Self.sampleMemories(),
            name: "settings_memory_populated_light"
        )
    }

    @Test("populated in dark")
    func populatedDark() async throws {
        try await verify(
            theme: .dark,
            memories: Self.sampleMemories(),
            name: "settings_memory_populated_dark"
        )
    }

    @Test("populated in sepia")
    func populatedSepia() async throws {
        try await verify(
            theme: .sepia,
            memories: Self.sampleMemories(),
            name: "settings_memory_populated_sepia"
        )
    }

    @Test("dynamic type XXL on populated")
    func populatedXXL() async throws {
        try await verify(
            theme: .light,
            memories: Self.sampleMemories(),
            dynamicType: .xxLarge,
            name: "settings_memory_populated_light_xxl"
        )
    }

    private static func sampleMemories() -> [MemoryEntry] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            MemoryEntry(id: "mem-1", text: "Prefers metric units.", createdAt: base, updatedAt: base),
            MemoryEntry(
                id: "mem-2",
                text: "Vegetarian — no fish either.",
                createdAt: base.addingTimeInterval(60),
                updatedAt: base.addingTimeInterval(60)
            ),
            MemoryEntry(
                id: "mem-3",
                text: "Lives in Tokyo (UTC+9); schedule meeting times accordingly.",
                createdAt: base.addingTimeInterval(120),
                updatedAt: base.addingTimeInterval(120)
            ),
        ]
    }

    private func verify(
        theme: SuperTheme.Identifier,
        memories: [MemoryEntry],
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBMemoryRepository(database: database)
        for memory in memories {
            try await repository.save(memory)
        }
        let viewModel = makeViewModel(memoryRepository: repository)
        viewModel._setSnapshotState(
            settings: .default,
            tools: [Self.memoryToolRow]
        )

        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .memory,
            databaseContext: .readOnly { database.queue }
        )
        .superTheme(.make(theme))
        .dynamicTypeSize(dynamicType)
        .frame(width: Self.frame.width, height: Self.frame.height)

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

    private static let memoryToolRow = SettingsViewModel.ToolRow(
        id: MemoryTool.toolID,
        name: "memory",
        summary: "Lets me remember preferences across conversations.",
        isEnabled: true,
        configPane: .memory
    )

    private func makeViewModel(memoryRepository: any MemoryRepository) -> SettingsViewModel {
        SettingsViewModel(
            accountEmail: "brianwang9100@gmail.com",
            appInfo: Self.appInfo,
            settingRepository: NoopSettingRepository(),
            modelRepository: NoopModelRepository(),
            conversationRepository: NoopConversationRepository(),
            toolRegistry: ToolRegistry(),
            systemPromptReceiver: FakeSystemPromptReceiver(),
            autoCompactPolicyReceiver: FakeAutoCompactPolicyReceiver(),
            memoryRepository: memoryRepository
        )
    }
}

/// Mirrors the harness in `SettingsSheetSnapshotTests` but accepts a
/// `DatabaseContext` so the memory pane's `@Query` can observe a real
/// in-memory database. The other snapshot suites pass `nil` and stay
/// unchanged.
private struct SettingsSheetSnapshotHarness: View {
    let viewModel: SettingsViewModel
    let initialPane: SettingsSheet.Pane
    let databaseContext: DatabaseContext?

    @State private var presented = true
    @Environment(\.superTheme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            SettingsSheet(
                isPresented: $presented,
                viewModel: viewModel,
                initialPane: initialPane,
                databaseContext: databaseContext
            )
        }
    }
}

private struct NoopSettingRepository: SettingRepository {
    func get(_ key: String) async throws -> String? { nil }
    func set(_ key: String, value: String) async throws {}
    func delete(_ key: String) async throws {}
    func all() async throws -> [String: String] { [:] }
}

private struct NoopModelRepository: ModelConfigurationRepository {
    func all() async throws -> [ModelConfigurationRecord] { [] }
    func fetch(id: String) async throws -> ModelConfigurationRecord? { nil }
    func selected() async throws -> ModelConfigurationRecord? { nil }
    func save(_ record: ModelConfigurationRecord) async throws {}
    func delete(id: String) async throws {}
    func setSelected(id: String) async throws {}
    func storeAPIKey(_ key: String, ref: String) async throws {}
    func loadAPIKey(ref: String) async throws -> String? { nil }
}

private struct NoopConversationRepository: ConversationRepository {
    func listActive() async throws -> [ConversationRecord] { [] }
    func fetch(id: String) async throws -> ConversationRecord? { nil }
    func save(_ record: ConversationRecord) async throws {}
    func softDelete(id: String, at deletedAt: Date) async throws {}
    func hardDelete(id: String) async throws {}
}
#endif
