import Foundation

public protocol HTTPClient: Sendable {
    /// Honors request timeout and yields transport chunks, not logical records;
    /// callers must rebuffer SSE or other framing. Non-2xx responses throw badStatus
    /// with the response body; transport failures propagate.
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

public enum HTTPError: Error, Sendable, Equatable {
    /// Retains the provider's error explanation; an absent body is an empty string.
    case badStatus(Int, body: String)
    case invalidResponse
    case transport(String)
}

// Delegate delivery avoids per-byte hops and supports chunked URLProtocol test stubs.
public final class URLSessionHTTPClient: HTTPClient {
    private let configuration: URLSessionConfiguration
    private let allowsRedirects: Bool

    public init(configuration: URLSessionConfiguration = .ephemeral, allowsRedirects: Bool = true) {
        self.configuration = configuration
        self.allowsRedirects = allowsRedirects
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamingDelegate(continuation: continuation, allowsRedirects: allowsRedirects)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)

            continuation.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }

            task.resume()
        }
    }
}

/// `@unchecked Sendable` is safe because URLSession serializes delegate callbacks
/// and `AsyncThrowingStream.Continuation` is thread-safe.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<Data, Error>.Continuation
    private let continuation: Continuation
    private let allowsRedirects: Bool

    // Consume error bodies instead of yielding/cancelling them; delegate access is serialized.
    private var errorStatusCode: Int?
    private var errorBody = Data()
    // Bound error-response buffering even if the server sends an excessive body.
    private static let maxErrorBodyBytes = 8 * 1024

    init(continuation: Continuation, allowsRedirects: Bool) {
        self.continuation = continuation
        self.allowsRedirects = allowsRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(allowsRedirects ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            errorStatusCode = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if errorStatusCode != nil {
            let remaining = Self.maxErrorBodyBytes - errorBody.count
            if remaining > 0 { errorBody.append(data.prefix(remaining)) }
            return
        }
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let errorStatusCode {
            let body = String(decoding: errorBody, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.finish(throwing: HTTPError.badStatus(errorStatusCode, body: body))
        } else if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
