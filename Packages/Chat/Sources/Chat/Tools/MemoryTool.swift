import Core
import Foundation

/// Built-in `ToolExecutor` that lets the LLM (Large Language Model) save,
/// update, and forget user preferences across conversations.
///
/// One tool with an `op` enum parameter rather than three sibling tools —
/// keeps the Settings tools pane to a single toggle and prevents the LLM
/// from enabling "save" without "forget" (which would let memory grow
/// without a recall path).
///
/// What gets *saved* is governed by the descriptor's `description` field
/// (read by the LLM when picking tools); what gets *recalled* lives in
/// `ContextAssembler`, which prepends saved memories to the system prompt
/// when this tool is enabled.
///
/// Clock and ID generator are injected so tests can assert deterministic
/// `MemoryEntry` ids and timestamps.
public struct MemoryTool: ToolExecutor {
    /// Stable identifier used by both the LLM advertisement and registry
    /// dispatch. No dot-namespace because there's only one verb-bundle
    /// here — the `op` parameter is the namespacing.
    public static let toolID = "memory"
    public static let appletID = "chat"

    public let toolID: String = MemoryTool.toolID

    private let repository: any MemoryRepository
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    public init(
        repository: any MemoryRepository,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator()
    ) {
        self.repository = repository
        self.clock = clock
        self.idGenerator = idGenerator
    }

    /// Operations the LLM may perform on the memory store.
    public enum Op: String, Sendable, Equatable, CaseIterable {
        case save
        case update
        case forget
    }

    /// Tool descriptor advertised to the LLM. The `description` is what
    /// trains the model on *when* to call this — keep it specific enough
    /// to discourage saving one-off context but permissive enough to
    /// capture real preferences.
    public static let descriptor: LLMTool = LLMTool(
        id: MemoryTool.toolID,
        name: "memory",
        description: """
        Persistent memory across conversations. Use `op:'save'` when the \
        user shares a stable preference, personal fact, or instruction \
        about how they want you to respond (e.g. "I prefer metric", \
        "I'm vegetarian", "always answer concisely"). Use `op:'update'` \
        when an existing memory needs revision and you know its id. Use \
        `op:'forget'` when the user contradicts a saved fact. Do NOT \
        save one-off context, transient questions, the contents of the \
        current task, or anything the user hasn't asserted about \
        themselves. Saved memories are automatically surfaced to you on \
        every future turn — you do not need to read them back.
        """,
        category: .mutation,
        parameters: [
            LLMToolParameter(
                name: "op",
                type: .string,
                description: "Which operation to perform.",
                isRequired: true,
                enumValues: Op.allCases.map(\.rawValue)
            ),
            LLMToolParameter(
                name: "text",
                type: .string,
                description: """
                The memory text. Required for `save` and `update`; \
                ignored for `forget`. Keep it short and self-contained \
                (a single sentence is ideal) so it makes sense without \
                conversation context.
                """,
                isRequired: false
            ),
            LLMToolParameter(
                name: "id",
                type: .string,
                description: """
                Identifier of an existing memory. Required for `update` \
                and `forget`; ignored for `save`. Ids come from a prior \
                `save` result or from the surfaced memory block.
                """,
                isRequired: false
            ),
        ],
        appletId: MemoryTool.appletID
    )

    /// Convenience that builds a `ToolRegistration` for a ready-to-use
    /// instance. Composition root calls this and hands the result to
    /// `ToolRegistry.register(_:)`.
    ///
    /// Default `isEnabled: false` — memory is opt-in. Surfacing every
    /// preference the user mentions without their say-so is the kind of
    /// behaviour that erodes trust in the first hour.
    public static func registration(
        repository: any MemoryRepository,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator(),
        isEnabled: Bool = false
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(MemoryTool(
                repository: repository,
                clock: clock,
                idGenerator: idGenerator
            )),
            isEnabled: isEnabled
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let op = parseOp(input["op"])
        switch op {
        case .ok(.save):
            return await runSave(text: stringValue(input["text"]))
        case .ok(.update):
            return await runUpdate(id: stringValue(input["id"]), text: stringValue(input["text"]))
        case .ok(.forget):
            return await runForget(id: stringValue(input["id"]))
        case .missing:
            return errorResult("Missing required parameter `op`. Pass one of: \(Op.allCases.map(\.rawValue).joined(separator: ", ")).")
        case .invalid(let raw):
            return errorResult("Unknown `op` value '\(raw)'. Pass one of: \(Op.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
    }

    // MARK: - Operations

    private func runSave(text: String?) async -> ToolResult {
        guard let text else {
            return errorResult("`op:'save'` requires a `text` parameter.")
        }
        let id = idGenerator.nextID()
        let now = clock.now()
        let entry = MemoryEntry(id: id, text: text, createdAt: now, updatedAt: now)
        do {
            try await repository.save(entry)
            return ToolResult(
                toolID: MemoryTool.toolID,
                content: "Saved memory \(id): \(text)",
                isError: false,
                artifacts: [
                    ToolResult.Artifact(
                        type: "memory",
                        id: id,
                        data: ["op": Op.save.rawValue, "text": text]
                    ),
                ]
            )
        } catch let error as MemoryRepositoryError {
            return errorResult(message(for: error))
        } catch {
            return errorResult("Could not save memory: \(error.localizedDescription)")
        }
    }

    private func runUpdate(id: String?, text: String?) async -> ToolResult {
        guard let id else {
            return errorResult("`op:'update'` requires an `id` parameter.")
        }
        guard let text else {
            return errorResult("`op:'update'` requires a `text` parameter.")
        }
        do {
            try await repository.update(id: id, text: text, updatedAt: clock.now())
            return ToolResult(
                toolID: MemoryTool.toolID,
                content: "Updated memory \(id): \(text)",
                isError: false,
                artifacts: [
                    ToolResult.Artifact(
                        type: "memory",
                        id: id,
                        data: ["op": Op.update.rawValue, "text": text]
                    ),
                ]
            )
        } catch let error as MemoryRepositoryError {
            return errorResult(message(for: error))
        } catch {
            return errorResult("Could not update memory: \(error.localizedDescription)")
        }
    }

    private func runForget(id: String?) async -> ToolResult {
        guard let id else {
            return errorResult("`op:'forget'` requires an `id` parameter.")
        }
        do {
            // Single transaction — without this the artifact's `text`
            // could race a concurrent Settings-pane update between the
            // read and the delete, and the expanded pill would show
            // stale content for what we just forgot.
            let priorText = (try await repository.fetchAndDelete(id: id))?.text
            return ToolResult(
                toolID: MemoryTool.toolID,
                content: "Forgot memory \(id).",
                isError: false,
                artifacts: [
                    ToolResult.Artifact(
                        type: "memory",
                        id: id,
                        data: ["op": Op.forget.rawValue, "text": priorText ?? ""]
                    ),
                ]
            )
        } catch {
            return errorResult("Could not forget memory: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private enum ParsedOp {
        case ok(Op)
        case missing
        case invalid(String)
    }

    private func parseOp(_ value: JSONValue?) -> ParsedOp {
        guard case .string(let raw) = value else {
            return .missing
        }
        if let op = Op(rawValue: raw) {
            return .ok(op)
        }
        return .invalid(raw)
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Return the trimmed form, not `raw`: `SettingsViewModel.updateMemory`
        // trims before writing, so without trimming here the two write
        // paths would leave different byte sequences for logically
        // equivalent memory text.
        return trimmed.isEmpty ? nil : trimmed
    }

    private func message(for error: MemoryRepositoryError) -> String {
        switch error {
        case .overCapacity(let limit):
            return "Memory is full (limit: \(limit) entries). Ask the user to remove an existing memory before saving a new one."
        case .textTooLong(let limit):
            return "Memory text is too long (limit: \(limit) characters). Try a shorter form."
        case .emptyText:
            return "Memory text is empty. Pass a non-empty `text`."
        case .notFound(let id):
            return "No memory with id '\(id)'. It may have been deleted; ask the user instead of guessing."
        }
    }

    private func errorResult(_ content: String) -> ToolResult {
        ToolResult(toolID: MemoryTool.toolID, content: content, isError: true)
    }
}
