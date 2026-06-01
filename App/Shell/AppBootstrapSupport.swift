import Chat
import Core
import Foundation

/// Bootstrap utilities shared by both `SuperOSAppBootstrap` and
/// `SuperBibleAppBootstrap`. The applet roster and per-applet briefing
/// stay target-specific (each bootstrap registers its own mix); the
/// generic plumbing — directory creation with `.complete` file
/// protection, provider hydration from persisted `ModelConfigurationRecord`s,
/// DEBUG-only `DebugLLMProvider` seeding — lives here so the two
/// composition roots stay in lock-step on what "first launch" means.
///
/// Lives in `App/Shell/` because that's the directory the SuperBible
/// target *also* compiles via the explicit project.yml file-inclusion
/// list (see `SuperBible.sources` in `project.yml`). Both targets see
/// the same source, so any future bootstrap change lands once.
enum AppBootstrapSupport {
    /// `Application Support/Super/`, created on first call and pinned to
    /// `FileProtectionType.complete` so its contents are unreadable while
    /// the device is locked. iOS-enforced; macOS test runs silently no-op
    /// the protection class without erroring.
    ///
    /// The directory is shared *inside* a given target's data container.
    /// The SuperOS and SuperBible apps have different bundle ids, so
    /// each gets its own `Application Support/` — their `Super/`
    /// directories sit in entirely separate containers and never see
    /// each other's `chat.sqlite`.
    static func defaultDataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "Super", directoryHint: .isDirectory)
    }

    /// Create `url` (and any missing parents) and pin its file-protection
    /// class to `.complete`. Files created inside inherit the directory's
    /// class by default, so this also covers the SQLite sidecar files
    /// (`-wal`, `-shm`, `-journal`) that GRDB may produce mid-transaction.
    /// Best-effort: the protection attribute is iOS-enforced; macOS test
    /// runs silently no-op.
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

    /// Read every persisted `ModelConfigurationRecord`, resolve its API key
    /// from the Keychain, and register the right `LLMProvider` for each
    /// row's `kind`. Registration order is creation-stable; the selected
    /// row is then promoted via `setActive(id:)` so the bootstrap doesn't
    /// depend on `LLMProviderRegistry`'s implementation detail of "first
    /// registered = active". An `.openAICompatible` row whose Keychain
    /// entry has been wiped registers anyway with a nil key — local
    /// servers (MLX, Ollama) don't require auth. An `.appleFoundation`
    /// row is only registered when the OS reports AFM as available; an
    /// unavailable device leaves the registry empty and the orchestrator
    /// falls back to its `noModelConfigured` banner.
    ///
    /// Deliberately *not* `@MainActor`-isolated, matching the pre-extraction
    /// version. The body is a tight loop of actor `await`s with no UI work;
    /// pinning it to main would make every iteration's synchronous bookkeeping
    /// (sort, switch dispatch, provider construction) contend with first-frame
    /// rendering during launch.
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
            switch record.kind {
            case .openAICompatible:
                let apiKey: String?
                if let ref = record.apiKeyRef {
                    apiKey = try? await repository.loadAPIKey(ref: ref)
                } else {
                    apiKey = nil
                }
                let provider = OpenAICompatibleLLMProvider(
                    configuration: record.configuration,
                    apiKey: apiKey,
                    http: http
                )
                await registry.register(provider)
            case .appleFoundation:
                // `id` must match the record UUID — `setActive(id:)` looks providers
                // up by this value; a static fallback would silently fail to promote
                // the seeded `isSelected = true` row to active.
                guard appleFoundationAvailability.isAvailable else { continue }
                let provider = AppleFoundationLLMProvider(
                    id: record.id,
                    availability: appleFoundationAvailability,
                    toolRegistry: toolRegistry
                )
                await registry.register(provider)
            case .anthropicNative, .geminiNative, .openAIResponses:
                // Native-search adapters land in a later PR; until then no
                // persisted row can carry a native `kind` (the Add-Model
                // native-search option ships with the adapters), so skip.
                // (`continue` here vs. `break` in `SettingsViewModel`'s
                // non-looping `registerProvider` switch — same intent:
                // register nothing for this row.)
                continue
            #if DEBUG
            case .debug:
                await registry.register(DebugLLMProvider(id: record.id))
            #endif
            }
        }

        if let selectedId = try await repository.selected()?.id {
            // The only failure mode is `unknownProvider`, which can only
            // happen if the selected row's kind was unavailable (AFM on
            // an ineligible device) and skipped above. The
            // first-registered fallback (or "no provider" empty state)
            // is the right behavior in that case.
            try? await registry.setActive(id: selectedId)
        }
    }

    #if DEBUG
    /// DEBUG-only first-launch seed: insert a `ModelConfigurationRecord`
    /// with `kind = .debug` so `DebugLLMProvider` shows up in the model
    /// picker without the user having to add a model manually. The
    /// existence check and the insert run in a single GRDB write
    /// transaction (via `insertDebugIfMissing`), so two concurrent
    /// `bootstrap()` calls — vanishingly rare in practice but trivial to
    /// close — can't both pass the empty check and then double-insert.
    /// `shouldSelect` is computed inside the same transaction, so the
    /// row is marked selected only when no other selection exists at the
    /// moment of insert; a developer who has already wired a real
    /// provider keeps that as active and just sees the debug entry as an
    /// alternative.
    static func seedDebugModelIfNeeded(
        repository: GRDBModelConfigurationRepository
    ) async throws {
        _ = try await repository.insertDebugIfMissing { shouldSelect in
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
    }
    #endif
}
