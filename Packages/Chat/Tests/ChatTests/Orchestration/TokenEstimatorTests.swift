import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `HeuristicTokenEstimator` — the chars/4 fallback used by
/// `ContextAssembler` and `Compactor`. Establishes the ratios are stable
/// (so a future real-tokenizer drop-in can be A/B compared) and that
/// message-level estimation rolls up the per-block costs.
@Suite("TokenEstimator")
struct TokenEstimatorTests {

    @Test func emptyStringReturnsZero() {
        let estimator = HeuristicTokenEstimator()
        #expect(estimator.estimate("") == 0)
    }

    @Test func shortStringRoundsUpToOneToken() {
        let estimator = HeuristicTokenEstimator()
        // 1–4 chars → 1 token.
        #expect(estimator.estimate("a") == 1)
        #expect(estimator.estimate("abcd") == 1)
        // 5–8 chars → 2 tokens.
        #expect(estimator.estimate("abcde") == 2)
        #expect(estimator.estimate("abcdefgh") == 2)
    }

    @Test func englishProseRatioIsStable() {
        let estimator = HeuristicTokenEstimator()
        let prose = "The quick brown fox jumps over the lazy dog and naps."
        // 54 chars → ceil(54/4) = 14
        #expect(estimator.estimate(prose) == 14)
    }

    @Test func denseCodeOvershootsButStays4to1() {
        let estimator = HeuristicTokenEstimator()
        let code = "let x: Int = 42; let y: String = \"hello\"; print(x + y.count)"
        // 60 chars → 15 tokens (overshoots — real tokenizer would emit
        // closer to ~20 tokens for code, but overshooting the budget is
        // safe).
        #expect(estimator.estimate(code) == 15)
    }

    @Test func messagesArrayRollsUpEveryBlockKind() {
        let estimator = HeuristicTokenEstimator()
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: "You are helpful."),
            LLMMessage(role: .user, text: "Hi there."),
            LLMMessage(role: .assistant, content: [
                .text("Sure thing."),
                .toolUse(id: "t1", name: "echo", input: .object(["text": .string("ping")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "t1", content: "pong", isError: false),
            ]),
        ]
        let total = estimator.estimate(messages: messages)
        // Sanity: total is positive and exceeds the longest single block,
        // proving the rollup actually adds across blocks.
        #expect(total > estimator.estimate("You are helpful."))
        #expect(total > 0)
    }

    @Test func toolUseInputContributesToBudget() {
        // A bloated tool-use input should noticeably increase the
        // estimate — this prevents an "ignore tool args" regression that
        // would let a 50-key payload pass under the radar.
        let estimator = HeuristicTokenEstimator()
        let small = LLMMessage(role: .assistant, content: [
            .toolUse(id: "t1", name: "k", input: .object(["a": .string("x")]), signature: nil),
        ])
        let large = LLMMessage(role: .assistant, content: [
            .toolUse(id: "t1", name: "k", input: .object([
                "a": .string(String(repeating: "x", count: 200)),
            ]), signature: nil),
        ])
        #expect(estimator.estimate(messages: [large]) > estimator.estimate(messages: [small]))
    }

    // MARK: - Tool-schema estimation

    private func tool(
        name: String,
        description: String,
        parameters: [LLMToolParameter]
    ) -> LLMTool {
        LLMTool(
            id: name,
            name: name,
            description: description,
            category: .query,
            parameters: parameters,
            appletId: "test"
        )
    }

    @Test func emptyToolsReturnZero() {
        let estimator = HeuristicTokenEstimator()
        #expect(estimator.estimate(tools: []) == 0)
    }

    @Test func toolCostCountsNameDescriptionAndParams() {
        let estimator = HeuristicTokenEstimator()
        let echo = tool(
            name: "echo",
            description: "Echoes the input text back to the caller.",
            parameters: [
                LLMToolParameter(name: "text", type: .string, description: "What to echo."),
            ]
        )
        let cost = estimator.estimate(tools: [echo])
        // The estimate must include at least the name + description + the
        // parameter's own description — proving none of the three are dropped.
        let floor = estimator.estimate("echo")
            + estimator.estimate("Echoes the input text back to the caller.")
            + estimator.estimate("What to echo.")
        #expect(cost >= floor)
        #expect(cost > 0)
    }

    @Test func toolParametersIncreaseTheEstimate() {
        // A tool that declares parameters costs more than the same tool with
        // none — the parameter schema is real window weight.
        let estimator = HeuristicTokenEstimator()
        let bare = tool(name: "noop", description: "Does nothing.", parameters: [])
        let withParams = tool(
            name: "noop",
            description: "Does nothing.",
            parameters: [
                LLMToolParameter(name: "mode", type: .string, description: "Operating mode.", enumValues: ["fast", "slow"]),
            ]
        )
        #expect(estimator.estimate(tools: [withParams]) > estimator.estimate(tools: [bare]))
    }

    @Test func nestedValueSchemaIsCounted() {
        // A parameter whose elements carry a nested object schema must cost
        // more than the same parameter without it — the recursion can't drop
        // deeply-shaped parameters (e.g. read's array-of-objects passages).
        let estimator = HeuristicTokenEstimator()
        let flat = tool(
            name: "read",
            description: "Reads passages.",
            parameters: [
                LLMToolParameter(name: "passages", type: .array, description: "Passages to read."),
            ]
        )
        let nested = tool(
            name: "read",
            description: "Reads passages.",
            parameters: [
                LLMToolParameter(
                    name: "passages",
                    type: .array,
                    description: "Passages to read.",
                    valueSchema: .array(element: .object([
                        LLMToolParameter(name: "book", type: .string, description: "Book to read."),
                        LLMToolParameter(name: "chapter", type: .integer, description: "Chapter number."),
                    ]))
                ),
            ]
        )
        #expect(estimator.estimate(tools: [nested]) > estimator.estimate(tools: [flat]))
    }

    @Test func toolsArrayRollsUpAcrossTools() {
        let estimator = HeuristicTokenEstimator()
        let a = tool(name: "a", description: "First tool.", parameters: [])
        let b = tool(name: "b", description: "Second tool.", parameters: [])
        #expect(
            estimator.estimate(tools: [a, b])
                == estimator.estimate(tools: [a]) + estimator.estimate(tools: [b])
        )
    }
}
