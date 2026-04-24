import Foundation

/// HTTP (HyperText Transfer Protocol) endpoint a remote tool POSTs to. The
/// optional `apiKeyRef` is a Keychain reference; if present and resolvable,
/// the executor attaches the value as `Authorization: Bearer <key>`.
public struct RemoteToolEndpoint: Sendable, Equatable {
    public let url: URL
    public let apiKeyRef: String?
    public let timeout: TimeInterval

    public init(url: URL, apiKeyRef: String? = nil, timeout: TimeInterval = 30) {
        self.url = url
        self.apiKeyRef = apiKeyRef
        self.timeout = timeout
    }
}

/// `ToolExecutor` that POSTs the tool's input to a remote HTTP endpoint and
/// decodes the response as a `ToolResult`.
///
/// Scaffolded in M1 but not yet wired into any registered tool — the path
/// exists so the registry can grow remote tools later without an
/// architectural change. Tests cover the request/response shape via the
/// URLProtocol stub.
public struct RemoteHTTPToolExecutor: ToolExecutor {
    public let toolID: String
    public let endpoint: RemoteToolEndpoint
    public let httpClient: any HTTPClient
    public let keychain: any KeychainClient

    public init(
        toolID: String,
        endpoint: RemoteToolEndpoint,
        httpClient: any HTTPClient,
        keychain: any KeychainClient
    ) {
        self.toolID = toolID
        self.endpoint = endpoint
        self.httpClient = httpClient
        self.keychain = keychain
    }

    /// POSTs `{ "toolID": ..., "input": ... }` to `endpoint.url` and decodes
    /// the response as JSON.
    ///
    /// - Parameter input: The tool's argument object.
    /// - Returns: A `ToolResult` whose `toolID` is set to this executor's
    ///   `toolID` regardless of what the server echoes back.
    /// - Throws: Any error from the underlying `HTTPClient` (network /
    ///   non-2xx), or `HTTPError.transport` wrapping a JSON decode failure.
    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.timeoutInterval = endpoint.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let ref = endpoint.apiKeyRef, let key = try await keychain.getString(ref: ref) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: JSONValue] = [
            "toolID": .string(toolID),
            "input": .object(input),
        ]
        request.httpBody = try JSONEncoder().encode(body)

        var collected = Data()
        for try await chunk in httpClient.stream(request) {
            collected.append(chunk)
        }

        do {
            let decoded = try JSONDecoder().decode(RemoteToolResponse.self, from: collected)
            return ToolResult(
                toolID: toolID,
                content: decoded.content,
                isError: decoded.isError ?? false,
                artifacts: decoded.artifacts ?? []
            )
        } catch {
            throw HTTPError.transport("Failed to decode remote tool response: \(error)")
        }
    }

    private struct RemoteToolResponse: Decodable {
        let content: String
        let isError: Bool?
        let artifacts: [ToolResult.Artifact]?
    }
}
