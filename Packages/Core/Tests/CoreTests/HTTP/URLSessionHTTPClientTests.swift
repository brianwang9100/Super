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

    @Test(arguments: [false, true])
    func non2xxBodiesStayOutOfStreamAndRespectErrorLimit(oversized: Bool) async {
        let stubID = URLProtocolStub.newStubID()
        let chunks = oversized
            ? [String(repeating: "a", count: 4_096), String(repeating: "b", count: 5_000), "discarded"]
            : [" \nprovider ", "error\n "]
        let expectedBody = oversized
            ? String(repeating: "a", count: 4_096) + String(repeating: "b", count: 4_096)
            : "provider error"
        URLProtocolStub.register(stubID: stubID) { _ in
            URLProtocolStub.Response(statusCode: 500, chunks: chunks.map { Data($0.utf8) })
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        let request = URLRequest(url: URL(string: "https://example.test/fail")!)

        var caught: Error?
        var yielded: [Data] = []
        do {
            for try await chunk in client.stream(request) { yielded.append(chunk) }
        } catch {
            caught = error
        }
        #expect(yielded.isEmpty)
        #expect(caught as? HTTPError == .badStatus(500, body: expectedBody))
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

    @Test(.timeLimit(.minutes(1)))
    func cancellingConsumerStopsHeldOpenTransport() async throws {
        let stubID = URLProtocolStub.newStubID()
        let (starts, startContinuation) = AsyncStream<Void>.makeStream()
        let (stops, stopContinuation) = AsyncStream<Void>.makeStream()
        URLProtocolStub.register(stubID: stubID, onStart: {
            startContinuation.yield(())
            startContinuation.finish()
        }, onStop: {
            stopContinuation.yield(())
            stopContinuation.finish()
        }) { _ in
            URLProtocolStub.Response(finishes: false)
        }
        defer { URLProtocolStub.unregister(stubID: stubID) }

        let client = makeClient(stubID: stubID)
        // Keep URLSession's own timeout beyond the test deadline: a timeout
        // must not masquerade as successful consumer-driven cancellation.
        let request = URLRequest(url: URL(string: "https://example.test/cancel")!, timeoutInterval: 300)
        let consumer = Task {
            var received: [Data] = []
            for try await chunk in client.stream(request) {
                received.append(chunk)
            }
            return received
        }
        defer { consumer.cancel() }

        // The response remains open after starting. Only cancellation
        // can stop this transport; normal response completion cannot satisfy the test.
        var startIterator = starts.makeAsyncIterator()
        let started: Void? = await startIterator.next()
        consumer.cancel()
        let result = await consumer.result
        var stopIterator = stops.makeAsyncIterator()
        let stopped: Void? = await stopIterator.next()

        #expect(started != nil)
        #expect(stopped != nil)
        #expect(try result.get().isEmpty)
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
