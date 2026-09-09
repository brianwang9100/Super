/// Coalesces asynchronous context metadata queries and caches successful results.
/// Failures remain retryable; callers never replace missing metadata with a guess.
actor AppleFoundationContextProvider {
    private let query: @Sendable () async -> Result<Int, LLMError>
    private var cachedTokens: Int?
    private var queryRunning = false
    private var waiters: [Int: CheckedContinuation<Result<Int, LLMError>, Never>] = [:]
    private var nextWaiterID = 0

    init(query: @escaping @Sendable () async -> Result<Int, LLMError>) {
        self.query = query
    }

    func cachedContextTokens() -> Int? { cachedTokens }

    func resolve() async -> Result<Int, LLMError> {
        if Task.isCancelled { return .failure(.cancelled) }
        if let cachedTokens { return .success(cachedTokens) }
        nextWaiterID += 1
        let id = nextWaiterID
        let result: Result<Int, LLMError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can arrive before the handler/continuation registers.
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                waiters[id] = continuation
                if !queryRunning {
                    queryRunning = true
                    Task { finish(await query()) }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Completion may win the actor hop while the caller is already cancelled.
        return Task.isCancelled ? .failure(.cancelled) : result
    }

    private func cancelWaiter(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(returning: .failure(.cancelled))
        // The underlying query may ignore cancellation. Leave it coalesced for
        // other readers and cache only its real successful metadata, never cancellation.
    }

    private func finish(_ result: Result<Int, LLMError>) {
        queryRunning = false
        let resolved: Result<Int, LLMError>
        if case .success(let tokens) = result {
            if tokens > 0 {
                cachedTokens = tokens
                resolved = result
            } else {
                resolved = .failure(.providerError(
                    code: "apple_model_metadata_unavailable",
                    message: "Apple Intelligence returned an invalid context size. Try again shortly."
                ))
            }
        } else {
            resolved = result
        }
        let completed = waiters.values
        waiters.removeAll()
        for waiter in completed { waiter.resume(returning: resolved) }
    }
}
