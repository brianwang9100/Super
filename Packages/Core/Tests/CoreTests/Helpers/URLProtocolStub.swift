import Foundation
import os

/// URLProtocol-based stub for intercepting URLSession requests in tests.
///
/// Each test owns a unique `stubID` and uses `ephemeralConfiguration(stubID:)`
/// so concurrent test suites don't trample each other's stubs. The stub id
/// rides on every request via the `X-Stub-ID` header (added through the
/// session config's `httpAdditionalHeaders`), and `startLoading()` looks up
/// the registration by that header.
final class URLProtocolStub: URLProtocol {
    /// Synthetic response a test wants the stub to deliver.
    struct Response: Sendable {
        let statusCode: Int
        let chunks: [Data]
        let error: Error?

        init(statusCode: Int = 200, chunks: [Data] = [], error: Error? = nil) {
            self.statusCode = statusCode
            self.chunks = chunks
            self.error = error
        }
    }

    /// Per-`stubID` registration entry: the response factory and the list
    /// of requests the protocol has observed so far.
    private struct Registration: Sendable {
        let stub: @Sendable (URLRequest) -> Response
        var observedRequests: [URLRequest] = []
    }

    static let stubHeader = "X-Stub-ID"

    private static let registry = OSAllocatedUnfairLock<[String: Registration]>(initialState: [:])

    static func newStubID() -> String { UUID().uuidString }

    static func register(stubID: String, _ stub: @escaping @Sendable (URLRequest) -> Response) {
        registry.withLock { state in
            state[stubID] = Registration(stub: stub)
        }
    }

    static func unregister(stubID: String) {
        registry.withLock { state in
            _ = state.removeValue(forKey: stubID)
        }
    }

    static func observedRequests(stubID: String) -> [URLRequest] {
        registry.withLock { state in
            state[stubID]?.observedRequests ?? []
        }
    }

    static func ephemeralConfiguration(stubID: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        config.httpAdditionalHeaders = [stubHeader: stubID]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: stubHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let currentRequest = request
        guard let stubID = currentRequest.value(forHTTPHeaderField: Self.stubHeader) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolStub", code: -1))
            return
        }
        let lookup = Self.registry.withLock { state -> Registration? in
            guard var registration = state[stubID] else { return nil }
            registration.observedRequests.append(currentRequest)
            state[stubID] = registration
            return registration
        }
        guard let registration = lookup else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolStub", code: -2))
            return
        }
        let response = registration.stub(currentRequest)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let httpResponse = HTTPURLResponse(
            url: currentRequest.url ?? URL(string: "https://example.test")!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
