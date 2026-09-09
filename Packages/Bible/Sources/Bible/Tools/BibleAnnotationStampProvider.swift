import Core
import Foundation

/// Source and model provenance come from the caller's session, never tool input.
/// Empty modelId is valid and degrades the footer to generic AI attribution; callers
/// requiring strict attribution must validate model availability before dispatch.
public protocol BibleAnnotationStampProvider: Sendable {
    func stamp() async -> BibleAnnotationStamp
}

public struct BibleAnnotationStamp: Sendable, Equatable {
    public let source: BibleAnnotationSource
    public let modelId: String

    public init(source: BibleAnnotationSource, modelId: String) {
        self.source = source
        self.modelId = modelId
    }
}

/// Resolves the active provider's first model at execution time, falling back to empty modelId.
public struct ActiveModelBibleAnnotationStampProvider: BibleAnnotationStampProvider {
    private let registry: LLMProviderRegistry
    private let source: BibleAnnotationSource

    public init(registry: LLMProviderRegistry, source: BibleAnnotationSource = .user) {
        self.registry = registry
        self.source = source
    }

    public func stamp() async -> BibleAnnotationStamp {
        // This independent read can see a provider selected after dispatch began. Keep .first
        // resolution aligned with the dispatcher; eliminating the race requires carrying its
        // resolved model through ToolExecutor. Follow-up: #143.
        let modelId = await registry.active()?.supportedModels.first?.id ?? ""
        return BibleAnnotationStamp(source: source, modelId: modelId)
    }
}
