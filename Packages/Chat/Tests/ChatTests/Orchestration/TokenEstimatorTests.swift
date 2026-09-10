import Core
import Foundation
import Testing

@testable import Chat

@Suite("TokenEstimator")
struct TokenEstimatorTests {

    @Test func emptyStringReturnsZero() {
        let estimator = HeuristicTokenEstimator()
        #expect(estimator.estimate("") == 0)
    }

    @Test func shortStringRoundsUpToOneToken() {
        let estimator = HeuristicTokenEstimator()
        #expect(estimator.estimate("a") == 1)
        #expect(estimator.estimate("abcd") == 1)
        #expect(estimator.estimate("abcde") == 2)
        #expect(estimator.estimate("abcdefgh") == 2)
    }

    @Test func englishProseRatioIsStable() {
        let estimator = HeuristicTokenEstimator()
        let prose = "The quick brown fox jumps over the lazy dog and naps."
        #expect(estimator.estimate(prose) == 14)
    }

    @Test func denseCodeOvershootsButStays4to1() {
        let estimator = HeuristicTokenEstimator()
        let code = "let x: Int = 42; let y: String = \"hello\"; print(x + y.count)"
        #expect(estimator.estimate(code) == 15)
    }

    @Test func messagesArrayRollsUpEveryBlockKind() {
        let estimator = HeuristicTokenEstimator()
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: "1234"),                 // 1
            LLMMessage(role: .assistant, content: [
                .text("12345"),                                   // 2
                .thinking(content: "123456789", signature: nil),   // 3
                .thinking(content: "1234", signature: "12345"),    // 1 + 2
                .toolUse(id: "t1", name: "echo", input: .object(["x": .int(1)]), signature: nil), // 1 + 2
                .searchResult([
                    SourceCitation(id: "s1", title: "1234", url: URL(string: "https://example.test/1")!, snippet: "12345"), // 1 + 2
                    SourceCitation(id: "s2", title: "123456789", url: URL(string: "https://example.test/2")!), // 3
                ]),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "t1", content: "1234567890123", isError: false), // 4
            ]),
        ]
        // Hand-counted per-block costs keep omitted fields visible in the total.
        #expect(estimator.estimate(messages: messages) == 22)
        #expect(estimator.estimate(messages: []) == 0)
    }

    @Test func toolUseInputContributesToBudget() {
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
        let floor = estimator.estimate("echo")
            + estimator.estimate("Echoes the input text back to the caller.")
            + estimator.estimate("What to echo.")
        #expect(cost >= floor)
        #expect(cost > 0)
    }

    @Test func toolParametersIncreaseTheEstimate() {
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
