import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `MemoryTool` — descriptor shape, op enum dispatch, parameter
/// validation, repository error mapping, and artifact emission so the
/// transcript pill can render without parsing natural language.
@Suite("MemoryTool")
struct MemoryToolTests {

    private static let fixedInstant = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTool() -> (MemoryTool, GRDBMemoryRepository, DeterministicIDGenerator) {
        let database = try! ChatDatabase.makeInMemory()
        let repository = GRDBMemoryRepository(database: database)
        let ids = DeterministicIDGenerator(prefix: "mem-")
        let tool = MemoryTool(
            repository: repository,
            clock: FixedClock(Self.fixedInstant),
            idGenerator: ids
        )
        return (tool, repository, ids)
    }

    // MARK: - Descriptor

    @Test func descriptorAdvertisesOpAndOptionalTextId() {
        let tool = MemoryTool.descriptor
        #expect(tool.id == "memory")
        #expect(tool.name == "memory")
        #expect(tool.category == .mutation)
        #expect(tool.appletId == MemoryTool.appletID)
        #expect(tool.parameters.count == 3)

        let op = tool.parameters[0]
        #expect(op.name == "op")
        #expect(op.type == .string)
        #expect(op.isRequired == true)
        #expect(op.enumValues == ["save", "update", "forget"])

        let text = tool.parameters[1]
        #expect(text.name == "text")
        #expect(text.isRequired == false)

        let id = tool.parameters[2]
        #expect(id.name == "id")
        #expect(id.isRequired == false)
    }

    @Test func registrationDefaultsToDisabled() async throws {
        let database = try ChatDatabase.makeInMemory()
        let registration = MemoryTool.registration(
            repository: GRDBMemoryRepository(database: database)
        )
        #expect(registration.tool.id == MemoryTool.toolID)
        #expect(registration.isEnabled == false)
        guard case .local = registration.execution else {
            Issue.record("expected .local execution")
            return
        }
    }

    // MARK: - Save

    @Test func savePersistsEntryAndReturnsId() async throws {
        let (tool, repository, _) = makeTool()

        let result = try await tool.execute(input: [
            "op": .string("save"),
            "text": .string("Prefers metric units."),
        ])

        #expect(result.isError == false)
        #expect(result.content.contains("mem-1"))
        #expect(result.content.contains("Prefers metric units."))
        #expect(result.artifacts.count == 1)
        let artifact = result.artifacts[0]
        #expect(artifact.type == "memory")
        #expect(artifact.id == "mem-1")
        #expect(artifact.data["op"] == "save")
        #expect(artifact.data["text"] == "Prefers metric units.")

        let stored = try await repository.all()
        #expect(stored.count == 1)
        #expect(stored[0].text == "Prefers metric units.")
        #expect(stored[0].createdAt == Self.fixedInstant)
    }

    @Test func saveTrimsSurroundingWhitespaceBeforeStoring() async throws {
        // Regression for PR #72: `stringValue` returned the raw
        // (untrimmed) string, so an LLM payload like
        // `"  prefer metric  "` stored verbatim with its spaces while
        // SettingsViewModel.updateMemory trimmed before writing —
        // leaving the two write paths with different byte sequences
        // for logically equivalent text.
        let (tool, repository, _) = makeTool()

        let result = try await tool.execute(input: [
            "op": .string("save"),
            "text": .string("  prefer metric  "),
        ])

        #expect(result.isError == false)
        let stored = try await repository.all()
        #expect(stored.count == 1)
        #expect(stored[0].text == "prefer metric")
    }

    @Test func saveMissingTextIsSoftError() async throws {
        let (tool, repository, _) = makeTool()

        let result = try await tool.execute(input: ["op": .string("save")])

        #expect(result.isError == true)
        #expect(result.content.contains("text"))
        #expect(try await repository.all().isEmpty)
    }

    @Test func saveOverCapacityReportsCleanly() async throws {
        let (tool, repository, _) = makeTool()
        for i in 0..<MemoryLimits.maxEntries {
            try await repository.save(MemoryEntry(
                id: "seed-\(i)",
                text: "fact \(i)",
                createdAt: Self.fixedInstant.addingTimeInterval(TimeInterval(i)),
                updatedAt: Self.fixedInstant.addingTimeInterval(TimeInterval(i))
            ))
        }

        let result = try await tool.execute(input: [
            "op": .string("save"),
            "text": .string("one too many"),
        ])

        #expect(result.isError == true)
        #expect(result.content.contains("\(MemoryLimits.maxEntries)"))
    }

    // MARK: - Update

    @Test func updateRewritesText() async throws {
        let (tool, repository, _) = makeTool()
        _ = try await tool.execute(input: [
            "op": .string("save"),
            "text": .string("Prefers metric."),
        ])

        let result = try await tool.execute(input: [
            "op": .string("update"),
            "id": .string("mem-1"),
            "text": .string("Prefers SI units."),
        ])

        #expect(result.isError == false)
        #expect(result.artifacts.first?.data["op"] == "update")
        #expect(try await repository.fetch(id: "mem-1")?.text == "Prefers SI units.")
    }

    @Test func updateMissingIdIsSoftError() async throws {
        let (tool, _, _) = makeTool()
        let result = try await tool.execute(input: [
            "op": .string("update"),
            "text": .string("x"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("id"))
    }

    @Test func updateUnknownIdReportsCleanly() async throws {
        let (tool, _, _) = makeTool()
        let result = try await tool.execute(input: [
            "op": .string("update"),
            "id": .string("ghost"),
            "text": .string("x"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("ghost"))
    }

    // MARK: - Forget

    @Test func forgetRemovesRowAndCarriesPriorTextInArtifact() async throws {
        let (tool, repository, _) = makeTool()
        _ = try await tool.execute(input: [
            "op": .string("save"),
            "text": .string("Vegetarian."),
        ])

        let result = try await tool.execute(input: [
            "op": .string("forget"),
            "id": .string("mem-1"),
        ])

        #expect(result.isError == false)
        #expect(result.artifacts.first?.data["op"] == "forget")
        #expect(result.artifacts.first?.data["text"] == "Vegetarian.")
        #expect(try await repository.all().isEmpty)
    }

    @Test func forgetUnknownIdSucceedsSilently() async throws {
        // `delete` is no-op on missing rows in the repository, and the
        // tool surfaces that as a clean success — the LLM should not
        // re-try on a forget that already happened.
        let (tool, _, _) = makeTool()
        let result = try await tool.execute(input: [
            "op": .string("forget"),
            "id": .string("nope"),
        ])
        #expect(result.isError == false)
    }

    // MARK: - Op parsing

    @Test func missingOpIsSoftError() async throws {
        let (tool, _, _) = makeTool()
        let result = try await tool.execute(input: [:])
        #expect(result.isError == true)
        #expect(result.content.contains("op"))
    }

    @Test func unknownOpIsSoftError() async throws {
        let (tool, _, _) = makeTool()
        let result = try await tool.execute(input: ["op": .string("delete")])
        #expect(result.isError == true)
        #expect(result.content.contains("delete"))
    }
}
