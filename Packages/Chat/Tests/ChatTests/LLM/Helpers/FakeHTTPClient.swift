import Core
import Foundation

/// In-memory `HTTPClient` for replaying recorded SSE (Server-Sent Events)
/// fixtures into provider tests. Records the issued `URLRequest` for
/// header/body assertions and yields the configured chunks in order.
/// Pass `error` to simulate transport failure or a non-2xx response
/// (the provider treats `HTTPError`s identically regardless of source).
struct FakeHTTPClient: HTTPClient {
    let chunks: [Data]
    let error: Error?
    let observed: ObservedRequests

    init(chunks: [Data] = [], error: Error? = nil) {
        self.chunks = chunks
        self.error = error
        self.observed = ObservedRequests()
    }

    /// Convenience that splits a full fixture string into a configurable
    /// number of byte chunks, exercising the SSE parser's partial-frame
    /// handling. `chunkCount = 1` mirrors a single-shot delivery; higher
    /// counts simulate an upstream that flushes frequently.
    static func fromFixture(_ text: String, chunkCount: Int = 1) -> FakeHTTPClient {
        let bytes = Data(text.utf8)
        guard chunkCount > 1, bytes.count >= chunkCount else {
            return FakeHTTPClient(chunks: [bytes])
        }
        let stride = bytes.count / chunkCount
        var chunks: [Data] = []
        var offset = 0
        for i in 0..<chunkCount {
            let end = (i == chunkCount - 1) ? bytes.count : offset + stride
            chunks.append(bytes.subdata(in: offset..<end))
            offset = end
        }
        return FakeHTTPClient(chunks: chunks)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        observed.append(request)
        let chunks = chunks
        let error = error
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

/// Thread-safe ledger of every `URLRequest` the fake client has been
/// asked to stream. Tests pull it after the stream completes to inspect
/// method, headers, and body without racing the producer.
final class ObservedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        storage.append(request)
    }

    var all: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
