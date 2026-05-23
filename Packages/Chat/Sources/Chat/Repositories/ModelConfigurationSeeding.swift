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
        let existing = try await repository.all()
        guard existing.isEmpty else { return nil }

        let record = ModelConfigurationRecord(
            id: idGenerator.nextID(),
            name: "Apple Intelligence",
            baseURL: nil,
            apiKeyRef: nil,
            modelId: "system-default",
            createdAt: clock.now(),
            kind: .appleFoundation,
            supportsThinking: false,
            // AFM context window is 4096 tokens on iOS 26.0–26.3 (the
            // value `AppleFoundationLLMProvider.defaultMaxContextTokens`
            // exposes). Hard-coding here rather than importing Core's
            // constant keeps the seed independent of which provider
            // class lands first.
            maxContextTokens: 4_096,
            isSelected: true
        )
        try await repository.save(record)
        return record
    }
}
