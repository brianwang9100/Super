import Core
import Foundation

/// Replays chunks, records requests, and optionally throws after the chunks.
struct FakeHTTPClient: HTTPClient {
    let chunks: [Data]
    let error: Error?
    let observed: ObservedRequests

    init(chunks: [Data] = [], error: Error? = nil) {
        self.chunks = chunks
        self.error = error
        self.observed = ObservedRequests()
    }

    /// Splits fixture bytes to exercise partial SSE frames.
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
