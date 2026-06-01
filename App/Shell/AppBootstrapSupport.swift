import Chat
import Core
import Foundation
import os

/// Bootstrap-path diagnostics. File-scoped so the static helpers below and
/// any future bootstrap telemetry share one `Logger` under the
/// `app-bootstrap` category.
private let bootstrapLog = Logger(subsystem: "com.brianwang.Super", category: "app-bootstrap")

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
            let apiKey: String?
            if let ref = record.apiKeyRef {
                apiKey = try? await repository.loadAPIKey(ref: ref)
            } else {
                apiKey = nil
            }
            // Single per-kind dispatch shared with `SettingsViewModel
            // .registerProvider` via `makeLLMProvider`, so the launch path and
            // the Settings path can't drift on which kinds are buildable.
            if let provider = makeLLMProvider(
                for: record,
                apiKey: apiKey,
                http: http,
                toolRegistry: toolRegistry,
                appleFoundationAvailability: appleFoundationAvailability
            ) {
                await registry.register(provider)
            } else if !record.kind.hasProviderAdapter {
                // A native-search kind whose adapter hasn't shipped yet
                // (`.anthropicNative`/`.geminiNative`). No persisted row
                // *should* carry one until the Add-Model native option ships
                // with that adapter, but a DB written by a *future* binary
                // (or synced from one) could. If it's also the selected row,
                // `selected()` filters it out (native kinds lack a buildable
                // adapter, so `buildableKindRequest` excludes them), so the
                // `setActive` below never sees a native id and the
                // first-registered fallback takes over cleanly. Log here so the
                // skip is diagnosable in the field rather than presenting as a
                // mute "no model configured".
                bootstrapLog.warning("Skipping model row \(record.id, privacy: .public) with native search kind \(record.kind.rawValue, privacy: .public) — native adapter not yet implemented")
            }
            // A `nil` for an `.appleFoundation` row on an AFM-ineligible device
            // is the silent expected path (the factory gated it); `selected()`
            // still returns it since AFM is buildable, and the throw below is
            // swallowed.
        }

        if let selectedId = try await repository.selected()?.id {
            // `setActive` throws `unknownProvider` when the selected row was
            // skipped above and never registered. The one path that reaches
            // here is an `.appleFoundation` row on an AFM-ineligible device:
            // AFM has a buildable adapter, so `selected()`'s
            // `buildableKindRequest` still returns it even though the loop
            // above skipped registration. The first-registered fallback (or
            // the "no provider" empty state) is the right behavior, so the
            // throw is swallowed.
            //
            // Native-kind rows do NOT reach here: `selected()` excludes them
            // (native kinds lack `hasProviderAdapter`, so
            // `buildableKindRequest` filters them out), so a native-only
            // selection returns nil / the next buildable row rather than a
            // native id. The hydration-loop skip is still logged above for
            // field diagnosability.
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
