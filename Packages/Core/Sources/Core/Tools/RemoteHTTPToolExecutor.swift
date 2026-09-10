import Foundation

/// apiKeyRef resolves through Keychain for a bearer token, subject to URLSecurity policy.
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

    /// Replaces any server-echoed tool identifier with this executor's `toolID`.
    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.timeoutInterval = endpoint.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // URLSecurity restricts credentials to HTTPS or trusted local hosts.
        if let ref = endpoint.apiKeyRef,
           isCleartextSafeForCredentials(endpoint.url),
           let key = try await keychain.getString(ref: ref) {
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
