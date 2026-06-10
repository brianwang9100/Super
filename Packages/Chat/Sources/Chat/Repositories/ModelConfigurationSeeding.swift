import Core
import Foundation

/// Helpers for seeding the `modelConfiguration` table on first launch.
///
/// Fresh installs ship with no provider rows, so the Chat applet opens
/// onto the `noModelConfigured` empty state — bad first impression. The
/// composition root calls `seedDefaultIfEmpty` before hydrating
/// providers; on a genuinely empty database it inserts one
/// `.appleFoundation` row (zero-config, on-device, free) and marks it
/// `isSelected = true` so the existing `LLMProviderRegistry.setActive`
/// path picks it up.
///
/// The seeded row is a regular `ModelConfigurationRecord` — not a
/// privileged singleton. Users can delete it like any other model;
/// nothing here re-creates it on later launches once the table has any
/// row. That preserves user agency: someone who removes AFM and adds
/// only Gemini doesn't get AFM silently brought back.
public enum ModelConfigurationSeeding {
    /// Seed a default `.appleFoundation` row when the repository is
    /// empty. No-op when any row already exists. `idGenerator` and
    /// `clock` are injected so tests can pin both.
    ///
    /// - Returns: The seeded record, or `nil` when the table already
    ///   had rows (no seed performed).
    @discardableResult
    public static func seedDefaultIfEmpty(
        repository: any ModelConfigurationRepository,
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
                name: AppleFoundationLLMProvider.defaultModelDisplayName,
                baseURL: nil,
                apiKeyRef: nil,
                modelId: AppleFoundationLLMProvider.defaultModelID,
                createdAt: clock.now(),
                kind: .appleFoundation,
                supportsThinking: false,
                // Persist the real on-device window so the row is honest. The
                // AFM provider re-reads it live at init regardless, so this is
                // cosmetic for budgeting — but it keeps the stored value true.
                maxContextTokens: AppleFoundationLLMProvider.deviceContextTokens,
                isSelected: true
            )
        }
    }
}
