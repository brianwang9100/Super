import Testing
import Foundation
@testable import Core

/// Tests for `URLSessionHTTPClient` driven by the per-test `URLProtocolStub`.
/// Covers chunked success, status-code failure, transport-error propagation,
/// and request observation.
@Suite("URLSessionHTTPClient")
struct URLSessionHTTPClientTests {
    private func makeClient(stubID: String) -> URLSessionHTTPClient {
        URLSessionHTTPClient(configuration: URLProtocolStub.ephemeralConfiguration(stubID: stubID))
    }

    @Test func streamsSingleChunkSuccessfully() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(statusCode: 200, chunks: [Data("hello".utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        let request = URLRequest(url: URL(string: "https://example.test/stream")!)

        var collected = Data()
        for try await chunk in client.stream(request) {
            collected.append(chunk)
        }
        #expect(collected == Data("hello".utf8))
    }

    @Test func streamsMultipleChunksInOrder() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(statusCode: 200, chunks: [
                Data("chunk1-".utf8),
                Data("chunk2-".utf8),
                Data("chunk3".utf8),
            ])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        let request = URLRequest(url: URL(string: "https://example.test/stream")!)

        var collected = Data()
        for try await chunk in client.stream(request) {
            collected.append(chunk)
        }
        #expect(String(data: collected, encoding: .utf8) == "chunk1-chunk2-chunk3")
    }

    @Test func throwsBadStatusForNon2xx() async {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(statusCode: 500, chunks: [Data("error".utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        let request = URLRequest(url: URL(string: "https://example.test/fail")!)

        var caught: Error?
        do {
            for try await _ in client.stream(request) {}
        } catch {
            caught = error
        }
        if case .badStatus(let code) = caught as? HTTPError {
            #expect(code == 500)
        } else {
            Issue.record("Expected HTTPError.badStatus, got \(String(describing: caught))")
        }
    }

    @Test func propagatesTransportErrors() async {
        let stubID = URLProtocolStub.newStubID()
        let expected = NSError(domain: "TestTransport", code: 42)
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(error: expected)
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        let request = URLRequest(url: URL(string: "https://example.test/boom")!)

        var caught: Error?
        do {
            for try await _ in client.stream(request) {}
        } catch {
            caught = error
        }
        let nsError = caught as NSError?
        #expect(nsError?.domain == "TestTransport")
        #expect(nsError?.code == 42)
    }

    @Test func consumerBreakingEarlyTerminatesStreamWithoutHanging() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(statusCode: 200, chunks: [
                Data("first".utf8),
                Data("second".utf8),
                Data("third".utf8),
            ])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        let request = URLRequest(url: URL(string: "https://example.test/early-break")!)

        var received: [Data] = []
        for try await chunk in client.stream(request) {
            received.append(chunk)
            break
        }

        // Breaking out of `for try await` orphans the stream's continuation,
        // which fires `onTermination` → `task.cancel()` + `session.finishTasksAndInvalidate()`.
        // The test reaching this assertion (rather than hanging) confirms that
        // path doesn't deadlock on session finalization.
        #expect(received.count == 1)
    }

    @Test func observesIssuedRequest() async throws {
        let stubID = URLProtocolStub.newStubID()
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(chunks: [Data("ok".utf8)])
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        var request = URLRequest(url: URL(string: "https://example.test/observe")!)
        request.httpMethod = "POST"
        request.setValue("test/value", forHTTPHeaderField: "X-Test")

        for try await _ in client.stream(request) {}

        let observed = URLProtocolStub.observedRequests(stubID: stubID)
        #expect(observed.count == 1)
        #expect(observed.first?.httpMethod == "POST")
        #expect(observed.first?.value(forHTTPHeaderField: "X-Test") == "test/value")
    }
}
