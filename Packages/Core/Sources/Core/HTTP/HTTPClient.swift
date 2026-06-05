import Foundation

/// Streaming HTTP (HyperText Transfer Protocol) client abstraction.
///
/// LLM (Large Language Model) responses arrive as long-lived HTTP streams,
/// so the protocol exposes `AsyncThrowingStream<Data, Error>` directly
/// rather than buffering whole bodies. Tests use a `URLProtocol`-based stub
/// to avoid hitting the network.
public protocol HTTPClient: Sendable {
    /// Issues `request` and yields response body chunks as they arrive.
    ///
    /// - Parameter request: Fully-formed URLRequest including method, body,
    ///   and headers. Conformers are expected to honor `request.timeoutInterval`.
    /// - Returns: A throwing async stream of body chunks. Chunk boundaries
    ///   reflect what the underlying transport delivers — callers that need
    ///   record-level framing (SSE, length-prefixed JSON, etc.) should
    ///   re-buffer. The stream finishes normally on completion and throws
    ///   `HTTPError.badStatus(_:)` on non-2xx status or the transport's own
    ///   error on failure.
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

/// Errors surfaced by `URLSessionHTTPClient`. Transport-level errors from
/// URLSession bubble up unchanged; this type covers the cases we synthesize
/// ourselves.
public enum HTTPError: Error, Sendable, Equatable {
    /// A non-2xx status, carrying the decoded response body when one was
    /// returned (empty string otherwise). The body is the provider's
    /// explanation — e.g. Gemini's "...items: missing field" on a 400 — so it
    /// must reach the error message rather than being discarded.
    case badStatus(Int, body: String)
    case invalidResponse
    case transport(String)
}

/// Production conformer using `URLSession` + `URLSessionDataDelegate`.
///
/// We use the delegate pattern (rather than `URLSession.bytes(for:)`) so we
/// can yield raw chunks without per-byte hops, and so `URLProtocol`-based
/// test stubs can deliver synthetic chunked responses.
public final class URLSessionHTTPClient: HTTPClient {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamingDelegate(continuation: continuation)
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

/// Bridges `URLSessionDataDelegate` callbacks into an
/// `AsyncThrowingStream.Continuation`. `@unchecked Sendable` because
/// URLSession invokes the delegate on its own queue and the continuation is
/// itself thread-safe.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<Data, Error>.Continuation
    private let continuation: Continuation

    /// Set when the response status is non-2xx. We then read (rather than
    /// cancel) the body so its bytes can be surfaced in `HTTPError.badStatus`,
    /// and route those bytes into `errorBody` instead of yielding them as
    /// stream content. Touched only on URLSession's serial delegate queue.
    private var errorStatusCode: Int?
    private var errorBody = Data()
    /// Cap on buffered error-body bytes — provider error payloads are small,
    /// and we never want a runaway error response to balloon memory.
    private static let maxErrorBodyBytes = 8 * 1024

    init(continuation: Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Allow the body to stream so we can capture the provider's
            // explanation; the enriched error is thrown in didCompleteWithError.
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
