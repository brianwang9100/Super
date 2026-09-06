/// Coalesces asynchronous context metadata queries and caches successful results.
/// Failures remain retryable; callers never replace missing metadata with a guess.
actor AppleFoundationContextProvider {
    private let query: @Sendable () async -> Result<Int, LLMError>
    private var cachedTokens: Int?
    private var pending: (id: Int, task: Task<Result<Int, LLMError>, Never>)?
    private var nextQueryID = 0

    init(query: @escaping @Sendable () async -> Result<Int, LLMError>) {
        self.query = query
    }

    func cachedContextTokens() -> Int? { cachedTokens }

    func resolve() async -> Result<Int, LLMError> {
        if let cachedTokens { return .success(cachedTokens) }
        let work: (id: Int, task: Task<Result<Int, LLMError>, Never>)
        if let pending {
            work = pending
        } else {
            nextQueryID += 1
            let query = self.query
            work = (nextQueryID, Task { await query() })
            pending = work
        }
        let result = await work.task.value
        if pending?.id == work.id {
            pending = nil
            if case .success(let tokens) = result, tokens > 0 {
                cachedTokens = tokens
            }
        }
        if case .success(let tokens) = result, tokens <= 0 {
            return .failure(.providerError(
                code: "apple_model_metadata_unavailable",
                message: "Apple Intelligence returned an invalid context size. Try again shortly."
            ))
        }
        return result
    }
}
