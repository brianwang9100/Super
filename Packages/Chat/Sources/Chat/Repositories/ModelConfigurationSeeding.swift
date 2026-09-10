import Core
import Foundation

public enum ModelConfigurationSeeding {
    /// Seed a selected on-device model when no buildable model exists; return nil otherwise.
    /// Call before provider hydration.
    @discardableResult
    public static func seedDefaultIfEmpty(
        repository: any ModelConfigurationRepository,
        idGenerator: any IDGenerator = UUIDGenerator(),
        clock: any Clock = SystemClock()
    ) async throws -> ModelConfigurationRecord? {
        try await repository.insertIfEmpty {
            ModelConfigurationRecord(
                id: idGenerator.nextID(),
                name: AppleFoundationLLMProvider.defaultModelDisplayName,
                baseURL: nil,
                apiKeyRef: nil,
                modelId: AppleFoundationLLMProvider.defaultModelID,
                createdAt: clock.now(),
                kind: .appleFoundation,
                supportsThinking: false,
                maxContextTokens: AppleFoundationLLMProvider.deviceContextTokens,
                isSelected: true
            )
        }
    }
}
