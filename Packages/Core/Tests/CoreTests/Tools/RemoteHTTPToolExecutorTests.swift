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
        endpointPath: String = "/tool",
        apiKeyRef: String? = nil,
        keychain: any KeychainClient = InMemoryKeychainClient()
    ) -> RemoteHTTPToolExecutor {
        let httpClient = URLSessionHTTPClient(configuration: URLProtocolStub.ephemeralConfiguration(stubID: stubID))
        let endpoint = RemoteToolEndpoint(
            url: URL(string: "https://example.test\(endpointPath)")!,
            apiKeyRef: apiKeyRef
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

        let executor = makeExecutor(stubID: stubID)
        let result = try await executor.execute(input: ["title": .string("demo")])

        #expect(result.toolID == "x.remote")
        #expect(result.content == "result text")
        #expect(result.isError == false)
        #expect(result.artifacts == [.init(type: "todo_item", id: "42", data: ["title": "demo"])])

        let observed = URLProtocolStub.observedRequests(stubID: stubID)
        #expect(observed.first?.httpMethod == "POST")
        #expect(observed.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
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
}
