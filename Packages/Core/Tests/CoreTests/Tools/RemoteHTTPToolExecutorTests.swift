import Testing
import Foundation
@testable import Core

/// Tests for `RemoteHTTPToolExecutor`'s request shape, optional bearer-token
/// attachment, and JSON-decode error handling.
@Suite("RemoteHTTPToolExecutor")
struct RemoteHTTPToolExecutorTests {
    private func makeExecutor(
        stubID: String,
        toolID: String = "x.remote",
        endpointURL: URL = URL(string: "https://example.test/tool")!,
        timeout: TimeInterval = 30,
        apiKeyRef: String? = nil,
        keychain: any KeychainClient = InMemoryKeychainClient()
    ) -> RemoteHTTPToolExecutor {
        let httpClient = URLSessionHTTPClient(configuration: URLProtocolStub.ephemeralConfiguration(stubID: stubID))
        let endpoint = RemoteToolEndpoint(
            url: endpointURL,
            apiKeyRef: apiKeyRef,
            timeout: timeout
        )
        return RemoteHTTPToolExecutor(
            toolID: toolID,
            endpoint: endpoint,
            httpClient: httpClient,
            keychain: keychain
        )
    }

    @Test func postsBodyAndDecodesResponse() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            let body = #"""
            {"content": "result text", "isError": false, "artifacts": [{"type": "todo_item", "id": "42", "data": {"title": "demo"}}]}
            """#
            return URLProtocolStub.Response(chunks: [Data(body.utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let endpointURL = URL(string: "https://example.test/custom-tool?mode=integration")!
        let executor = makeExecutor(stubID: stubID, toolID: "audit.remote", endpointURL: endpointURL, timeout: 17)
        let result = try await executor.execute(input: ["title": .string("demo")])

        #expect(result.toolID == "audit.remote")
        #expect(result.content == "result text")
        #expect(result.isError == false)
        #expect(result.artifacts == [.init(type: "todo_item", id: "42", data: ["title": "demo"])])

        let observed = URLProtocolStub.observedRequests(stubID: stubID)
        #expect(observed.count == 1)
        let request = try #require(observed.first)
        #expect(request.url == endpointURL)
        #expect(request.timeoutInterval == 17)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder().decode([String: JSONValue].self, from: bodyData(from: request))
        #expect(body == ["toolID": .string("audit.remote"), "input": .object(["title": .string("demo")])])
    }

    private func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        // URLSession may expose the POST body as a stream to URLProtocol.
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            try #require(count >= 0, "Request body stream failed: \(String(describing: stream.streamError))")
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }

    @Test func attachesBearerTokenWhenKeychainHasKey() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(chunks: [Data(#"{"content": "ok"}"#.utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let keychain = InMemoryKeychainClient()
        try await keychain.setString("sk-1234", ref: "openai")

        let executor = makeExecutor(stubID: stubID, apiKeyRef: "openai", keychain: keychain)
        _ = try await executor.execute(input: [:])

        let observed = URLProtocolStub.observedRequests(stubID: stubID)
        #expect(observed.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1234")
    }

    @Test func throwsWhenServerReturnsInvalidJSON() async {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(chunks: [Data("not json".utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let executor = makeExecutor(stubID: stubID)
        var caught: Error?
        do {
            _ = try await executor.execute(input: [:])
        } catch {
            caught = error
        }
        #expect(caught is HTTPError)
    }

    @Test func omitsAuthorizationWhenKeychainEmpty() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(chunks: [Data(#"{"content": "ok"}"#.utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let executor = makeExecutor(stubID: stubID, apiKeyRef: "missing")
        _ = try await executor.execute(input: [:])

        let observed = URLProtocolStub.observedRequests(stubID: stubID)
        #expect(observed.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func omitsAuthorizationForCleartextNonLoopbackEndpoint() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(chunks: [Data(#"{"content": "ok"}"#.utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let keychain = InMemoryKeychainClient()
        try await keychain.setString("sk-leak-canary", ref: "remote")

        let executor = makeExecutor(
            stubID: stubID,
            endpointURL: URL(string: "http://example.com/tool")!,
            apiKeyRef: "remote",
            keychain: keychain
        )
        _ = try await executor.execute(input: [:])

        let observed = URLProtocolStub.observedRequests(stubID: stubID)
        #expect(observed.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
