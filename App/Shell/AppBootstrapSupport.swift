import Chat
import Core
import Foundation
import os

private let bootstrapLog = Logger(subsystem: "com.brianwang.Super", category: "app-bootstrap")

/// Shared bootstrap plumbing; applet rosters and briefings remain target-specific.
enum AppBootstrapSupport {
    /// Runs before the dependency graph is exposed, so recovery cannot sweep a live model edit's staged key.
    static func recoverModelAPIKeys(from repository: GRDBModelConfigurationRepository) async {
        do { try await repository.recoverStagedAPIKeysAtStartup() } catch {
            bootstrapLog.warning("Some unused model API keys could not be removed. Cleanup will retry on the next app launch.")
        }
    }

    /// Creates Application Support/Super inside the target's own container.
    /// `.complete` protection makes contents unavailable while iOS is locked; macOS ignores it.
    static func defaultDataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "Super", directoryHint: .isDirectory)
    }

    /// Creates parents with `.complete` protection, inherited by SQLite sidecars.
    /// Protection is enforced on iOS and ignored on macOS.
    static func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    /// Registers saved providers in creation order, then restores the selected provider.
    /// Missing keys are allowed for local servers; unavailable adapters/devices are skipped.
    /// Kept off the main actor so hydration does not contend with first-frame rendering.
    static func hydrateProviders(
        into registry: LLMProviderRegistry,
        from repository: any ModelConfigurationRepository,
        toolRegistry: ToolRegistry,
        appleFoundationAvailability: AppleFoundationAvailability
    ) async throws {
        let configurations = try await repository.all()
        guard !configurations.isEmpty else { return }

        let http = URLSessionHTTPClient()
        let ordered = configurations.sorted { $0.createdAt < $1.createdAt }
        for record in ordered {
            // Do not access Keychain for keyless or unsupported provider kinds.
            let apiKey: String?
            if record.kind.hasProviderAdapter, let ref = record.apiKeyRef {
                apiKey = try? await repository.loadAPIKey(ref: ref)
            } else {
                apiKey = nil
            }
            // Share provider construction with Settings so supported kinds stay consistent.
            if let provider = makeLLMProvider(
                for: record,
                apiKey: apiKey,
                http: http,
                toolRegistry: toolRegistry,
                appleFoundationAvailability: appleFoundationAvailability
            ) {
                await registry.register(provider)
            } else if !record.kind.hasProviderAdapter {
                // Diagnose unsupported saved kinds, including rows written by a newer binary.
                bootstrapLog.warning("Skipping model row \(record.id, privacy: .public) with native search kind \(record.kind.rawValue, privacy: .public) — native adapter not yet implemented")
            } else {
                // Unavailable on-device models are expected; malformed network rows are diagnosable here too.
                bootstrapLog.debug("Skipped buildable model row \(record.id, privacy: .public) kind \(record.kind.rawValue, privacy: .public) — provider construction returned nil (AFM unavailable or missing baseURL)")
            }
        }

        if let selectedId = try await repository.selected()?.id {
            // A selected provider may have been skipped (for example, AFM became unavailable).
            // Keep the first registered provider or empty state when restoring selection fails.
            try? await registry.setActive(id: selectedId)
        }
    }

    #if DEBUG
    /// Seeds debug choices transactionally by ID. Only canned streaming may claim an empty
    /// selection; existing selections are preserved. Include Todo only when its tool is registered.
    static func seedDebugModelIfNeeded(
        repository: GRDBModelConfigurationRepository,
        includesTodoTool: Bool = false
    ) async throws {
        _ = try await repository.insertDebugRowIfMissing(
            id: "debug-canned", selectable: true
        ) { shouldSelect in
            ModelConfigurationRecord(
                id: "debug-canned",
                name: "Debug (canned)",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: DebugLLMProvider.modelID,
                createdAt: Date(),
                kind: .debug,
                supportsThinking: true,
                maxContextTokens: DebugLLMProvider.maxContextTokens,
                isSelected: shouldSelect
            )
        }
        _ = try await repository.insertDebugRowIfMissing(
            id: "debug-annotate", selectable: false
        ) { _ in
            ModelConfigurationRecord(
                id: "debug-annotate",
                name: "Debug (annotate)",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: DebugAnnotateLLMProvider.modelID,
                createdAt: Date(),
                kind: .debug,
                supportsThinking: false,
                maxContextTokens: DebugAnnotateLLMProvider.maxContextTokens,
                isSelected: false
            )
        }
        _ = try await repository.insertDebugRowIfMissing(
            id: "debug-note", selectable: false
        ) { _ in
            ModelConfigurationRecord(
                id: "debug-note",
                name: "Debug (note)",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: DebugNoteLLMProvider.modelID,
                createdAt: Date(),
                kind: .debug,
                supportsThinking: false,
                maxContextTokens: DebugNoteLLMProvider.maxContextTokens,
                isSelected: false
            )
        }
        _ = try await repository.insertDebugRowIfMissing(
            id: "debug-read", selectable: false
        ) { _ in
            ModelConfigurationRecord(
                id: "debug-read",
                name: "Debug (read)",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: DebugReadLLMProvider.modelID,
                createdAt: Date(),
                kind: .debug,
                supportsThinking: false,
                maxContextTokens: DebugReadLLMProvider.maxContextTokens,
                isSelected: false
            )
        }
        _ = try await repository.insertDebugRowIfMissing(
            id: "debug-search", selectable: false
        ) { _ in
            ModelConfigurationRecord(
                id: "debug-search",
                name: "Debug (search)",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: DebugSearchLLMProvider.modelID,
                createdAt: Date(),
                kind: .debug,
                supportsThinking: false,
                maxContextTokens: DebugSearchLLMProvider.maxContextTokens,
                isSelected: false
            )
        }
        _ = try await repository.insertDebugRowIfMissing(
            id: "debug-highlight", selectable: false
        ) { _ in
            ModelConfigurationRecord(
                id: "debug-highlight",
                name: "Debug (highlight)",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: DebugHighlightLLMProvider.modelID,
                createdAt: Date(),
                kind: .debug,
                supportsThinking: false,
                maxContextTokens: DebugHighlightLLMProvider.maxContextTokens,
                isSelected: false
            )
        }
        // Exercise the search pipeline with canned responses and no API key.
        _ = try await repository.insertDebugRowIfMissing(
            id: "debug-mock-search", selectable: false
        ) { _ in
            ModelConfigurationRecord(
                id: "debug-mock-search",
                name: "Debug (mock search)",
                baseURL: nil,
                apiKeyRef: nil,
                modelId: DebugLLMProvider.modelID,
                createdAt: Date(),
                kind: .debug,
                supportsThinking: true,
                maxContextTokens: DebugLLMProvider.maxContextTokens,
                isSelected: false,
                // Mirrors Chat's internal NativeWebSearch.mockBackendValue; a unit test pins equality.
                searchBackend: "debug"
            )
        }
        if includesTodoTool {
            _ = try await repository.insertDebugRowIfMissing(
                id: "debug-todo", selectable: false
            ) { _ in
                ModelConfigurationRecord(
                    id: "debug-todo",
                    name: "Debug (todo)",
                    baseURL: nil,
                    apiKeyRef: nil,
                    modelId: DebugTodoLLMProvider.modelID,
                    createdAt: Date(),
                    kind: .debug,
                    supportsThinking: false,
                    maxContextTokens: DebugTodoLLMProvider.maxContextTokens,
                    isSelected: false
                )
            }
        }
    }
    #endif
}
