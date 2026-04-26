import Chat
import Core
import Foundation

/// End-to-end smoke test that drives the Chat orchestration layer
/// (`ChatSessionStore` → `ChatSession` → `OpenAICompatibleLLMProvider`)
/// against a live local LLM (Large Language Model) server.
///
/// Defaults target a local OpenAI-compatible MLX server. Override per env:
/// - `OMLX_BASE_URL`  — base URL ending in `/v1` (default `http://127.0.0.1:1111/v1`)
/// - `OMLX_API_KEY`   — bearer token (default `omlx-local-dev`)
/// - `OMLX_MODEL`     — model id (default `Qwen3.6-35B-A3B-bf16`)
/// - `OMLX_SKIP_TOOL` — set to `1` to skip the tool-use turn
@main
struct ChatLiveLLMScript {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("\nFATAL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURLString = env["OMLX_BASE_URL"] ?? "http://127.0.0.1:1111/v1"
        guard let baseURL = URL(string: baseURLString) else {
            throw ScriptError.badBaseURL(baseURLString)
        }
        let apiKey = env["OMLX_API_KEY"] ?? "omlx-local-dev"
        let modelID = env["OMLX_MODEL"] ?? "Qwen3.6-35B-A3B-bf16"
        let skipTool = (env["OMLX_SKIP_TOOL"] ?? "0") == "1"

        print("==> Configuration")
        print("    base URL: \(baseURL.absoluteString)")
        print("    model:    \(modelID)")
        print("    api key:  \(redact(apiKey))")
        print("    skip tool turn: \(skipTool)")

        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let conversationRepo = GRDBConversationRepository(database: database)

        let conversationId = "live-test-conv"
        let now = Date()
        try await conversationRepo.save(
            ConversationRecord(
                id: conversationId,
                title: "Live LLM smoke test",
                createdAt: now,
                updatedAt: now
            )
        )

        let model = LLMModel(
            id: modelID,
            displayName: modelID,
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: 32_768
        )
        let provider = OpenAICompatibleLLMProvider(
            id: "omlx-local",
            displayName: "omlx local",
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            http: URLSessionHTTPClient()
        )
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)

        let toolRegistry = ToolRegistry()
        let echoTool = LLMTool(
            id: "echo",
            name: "echo",
            description: "Echoes back the supplied text. Use this tool when explicitly asked to echo something.",
            category: .query,
            parameters: [
                LLMToolParameter(
                    name: "text",
                    type: .string,
                    description: "The text to echo back verbatim.",
                    isRequired: true
                ),
            ],
            appletId: "live-test"
        )
        await toolRegistry.register(
            ToolRegistration(tool: echoTool, execution: .local(EchoExecutor()))
        )

        let store = ChatSessionStore(
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry
        )
        let session = await store.session(for: conversationId)

        try await runTurn(
            label: "TURN 1 — plain text",
            session: session,
            model: model,
            prompt: "In one short sentence: what is the capital of France?"
        )

        if !skipTool {
            try await runTurn(
                label: "TURN 2 — tool use",
                session: session,
                model: model,
                prompt: "Call the `echo` tool with the text 'pong from echo', then in one sentence summarize what the tool returned."
            )
        }

        print("\n==> Final persisted transcript")
        let allMessages = try await messageRepo.fetchAll(conversationId: conversationId)
        for message in allMessages {
            let preview = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(160)
            let toolID = message.toolCallId.map { " (toolCallId=\($0))" } ?? ""
            print("    [\(message.role.rawValue)\(toolID)] \(preview)")
        }
        let allToolCalls = try await toolCallRepo.fetchByConversation(conversationId)
        if !allToolCalls.isEmpty {
            print("\n==> Persisted tool calls")
            for call in allToolCalls {
                print("    \(call.toolName) status=\(call.status.rawValue) params=\(call.parameters)")
            }
        }

        await store.shutdown()
        print("\n==> Done")
    }

    private static func runTurn(
        label: String,
        session: ChatSession,
        model: LLMModel,
        prompt: String
    ) async throws {
        print("\n==> \(label)")
        print("    prompt: \(prompt)")
        print("    --- stream ---")

        let stream = await session.send(text: prompt, model: model)
        var encounteredError: LLMError?

        for await event in stream {
            switch event {
            case .userMessageSaved(let m):
                write("[user saved] id=\(m.id)\n")
            case .textDelta(let chunk):
                write(chunk)
            case .thinkingDelta(let chunk):
                write("[thinking: \(chunk)]")
            case .toolCallStarted(let record):
                write("\n[tool started] \(record.toolName) params=\(record.parameters)\n")
            case .toolCallCompleted(let record, let result):
                let preview = result.content.prefix(160)
                write("[tool ok] \(record.toolName) -> \(preview)\n")
            case .toolCallFailed(let record, let message):
                write("[tool FAILED] \(record.toolName) err=\(message)\n")
            case .assistantMessageSaved(let m):
                write("\n[assistant saved] id=\(m.id) tokens=\(m.tokenCount.map(String.init) ?? "nil")\n")
            case .error(let err):
                encounteredError = err
                write("\n[error] \(err)\n")
            }
        }
        await session.waitUntilFinished()

        if let err = encounteredError {
            throw ScriptError.streamError(err)
        }
    }

    private static func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    private static func redact(_ key: String) -> String {
        guard key.count > 6 else { return "***" }
        return "\(key.prefix(4))…\(key.suffix(2))"
    }
}

/// Minimal in-process tool used so the script exercises the full
/// orchestration loop (LLM requests tool → registry dispatches →
/// `.tool` row written → next provider turn observes the result).
private struct EchoExecutor: ToolExecutor {
    let toolID = "echo"

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let text: String
        if case .string(let value) = input["text"] {
            text = value
        } else {
            text = ""
        }
        return ToolResult(toolID: toolID, content: "ECHO: \(text)", isError: false)
    }
}

private enum ScriptError: Error, CustomStringConvertible {
    case badBaseURL(String)
    case streamError(LLMError)

    var description: String {
        switch self {
        case .badBaseURL(let raw): return "OMLX_BASE_URL is not a valid URL: \(raw)"
        case .streamError(let err): return "stream emitted error: \(err)"
        }
    }
}
