import Core
import Foundation

/// Seeds the composition root's chosen Apple model into an empty model repository.
/// Existing configurations and selections remain unchanged; readiness does not
/// decide whether the persistent default is local or Private Cloud Compute (PCC).
public enum ModelConfigurationSeeding {
    /// Insert one selected Apple model using injected identity and metadata.
    /// The composition root chooses the variant by OS support; absent live
    /// context metadata uses that variant's static fallback, not another model.
    ///
    /// - Parameters:
    ///   - model: The OS-appropriate variant selected outside persistence logic.
    ///   - maxContextTokens: Resolved model metadata, or `nil` while unavailable.
    /// - Returns: The seeded record, or `nil` when the table already
    ///   had rows (no seed performed).
    @discardableResult
    public static func seedDefaultIfEmpty(
        repository: any ModelConfigurationRepository,
        model: AppleFoundationModel = .local,
        maxContextTokens: Int? = nil,
        idGenerator: any IDGenerator = UUIDGenerator(),
        clock: any Clock = SystemClock()
    ) async throws -> ModelConfigurationRecord? {
        // The record is built lazily *inside* `insertIfEmpty`'s write
        // transaction so `idGenerator.nextID()` is only consumed when
        // the table is actually empty. Production UUID generators are
        // unbounded, but `DeterministicIDGenerator` in tests would
        // otherwise silently advance its counter on every no-op call.
        try await repository.insertIfEmpty {
            ModelConfigurationRecord(
                id: idGenerator.nextID(),
                name: model.displayName,
                baseURL: nil,
                apiKeyRef: nil,
                modelId: model.rawValue,
                createdAt: clock.now(),
                kind: .appleFoundation,
                supportsThinking: false,
                maxContextTokens: maxContextTokens ?? model.fallbackContextTokens,
                isSelected: true
            )
        }
    }
}
