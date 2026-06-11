import Core
import Foundation
import Testing

@testable import Chat

/// Verifies `ChatSession`'s per-tier briefing selection: small-window
/// (`ModelContextTier.compact`) models receive the lean persona + the active
/// applet's compact briefing only, while full-tier models receive the
/// constructor-time stack unchanged.
@Suite("ChatSession briefing selection")
struct ChatSessionBriefingSelectionTests {

    private struct Setup {
        let provider: FakeLLMProvider
        let session: ChatSession
        let model: LLMModel
    }

    private func makeModel(maxContextTokens: Int) -> LLMModel {
        LLMModel(
            id: "test-model",
            displayName: "Test",
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: maxContextTokens
        )
    }

    private let briefings = [
        AppletBriefing(
            label: "Bible applet",
            body: "FULL-BIBLE-RULES",
            compactBody: "LEAN-BIBLE-RULES",
            appletID: "bible"
        ),
        AppletBriefing(
            label: "Todo applet",
            body: "FULL-TODO-RULES",
            compactBody: "LEAN-TODO-RULES",
            appletID: "todo"
        ),
    ]

    private func makeSetup(
        model: LLMModel,
        compactChatBriefing: String = "LEAN-PERSONA",
        activeAppletID: (@Sendable () async -> String?)? = { "bible" }
    ) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .messageStart(id: "m1", model: model.id),
            .textDelta(index: 0, text: "ok"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ])
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGen
        )
        let conversation = try await OrchestrationFixtures.seedConversation(
            in: database, id: "conv-briefing", clock: clock
        )
        let session = ChatSession(
            conversationId: conversation.id,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: ToolRegistry(),
            compactor: compactor,
            clock: clock,
            idGenerator: idGen,
            // The compact tier's fixed budget allowance alone would trip
            // auto-compaction on a small window with the default threshold;
            // this suite is about briefing text, not compaction.
            autoCompactEnabled: false,
            chatBriefing: "FULL-PERSONA",
            compactChatBriefing: compactChatBriefing,
            appletBriefings: briefings,
            activeAppletID: activeAppletID
        )
        return Setup(provider: provider, session: session, model: model)
    }

    /// The leading `.system` block of the first captured request.
    private func leadingSystemText(of setup: Setup) async -> String {
        let captured = await setup.provider.capturedRequests()
        guard let first = captured.first?.messages.first, first.role == .system,
              case .text(let body) = first.content.first
        else { return "" }
        return body
    }

    private func runOneTurn(_ setup: Setup) async {
        let stream = await setup.session.send(text: "hello", model: setup.model)
        for await _ in stream {}
        await setup.session.waitUntilFinished()
    }

    @Test func compactTierSendsLeanPersonaAndActiveAppletOnly() async throws {
        let setup = try await makeSetup(model: makeModel(maxContextTokens: 4_096))
        await runOneTurn(setup)
        let leading = await leadingSystemText(of: setup)
        #expect(leading.contains("LEAN-PERSONA"))
        #expect(leading.contains("LEAN-BIBLE-RULES"))
        #expect(!leading.contains("FULL-PERSONA"))
        #expect(!leading.contains("FULL-BIBLE-RULES"))
        // Active-applet-only: the inactive applet contributes nothing in
        // either variant.
        #expect(!leading.contains("FULL-TODO-RULES"))
        #expect(!leading.contains("LEAN-TODO-RULES"))
    }

    @Test func fullTierSendsFullStackForAllApplets() async throws {
        let setup = try await makeSetup(model: makeModel(maxContextTokens: 100_000))
        await runOneTurn(setup)
        let leading = await leadingSystemText(of: setup)
        #expect(leading.contains("FULL-PERSONA"))
        #expect(leading.contains("FULL-BIBLE-RULES"))
        #expect(leading.contains("FULL-TODO-RULES"))
        #expect(!leading.contains("LEAN-PERSONA"))
        #expect(!leading.contains("LEAN-BIBLE-RULES"))
    }

    @Test func compactTierFallsBackToFullPersonaWhenNoCompactAuthored() async throws {
        let setup = try await makeSetup(
            model: makeModel(maxContextTokens: 4_096),
            compactChatBriefing: ""
        )
        await runOneTurn(setup)
        let leading = await leadingSystemText(of: setup)
        #expect(leading.contains("FULL-PERSONA"))
    }

    @Test func compactTierKeepsAllBriefingsWhenActiveAppletUnknown() async throws {
        // An active id that matches no briefing (or a nil accessor) fails
        // open: better to spend window on extra rules than to drop the one
        // briefing the user actually needed.
        let setup = try await makeSetup(
            model: makeModel(maxContextTokens: 4_096),
            activeAppletID: { "ghost" }
        )
        await runOneTurn(setup)
        let leading = await leadingSystemText(of: setup)
        #expect(leading.contains("LEAN-BIBLE-RULES"))
        #expect(leading.contains("LEAN-TODO-RULES"))
    }
}
