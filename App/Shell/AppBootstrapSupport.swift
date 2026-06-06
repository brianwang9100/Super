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
            // Resolve the Keychain key only when this binary will actually
            // build a provider for the row (`hasProviderAdapter`) *and* the
            // row carries a key reference. This preserves the pre-factory
            // behavior of not touching the Keychain for keyless kinds
            // (`.appleFoundation`/`.debug` never set `apiKeyRef`) or for
            // not-yet-buildable native kinds whose key we'd only discard.
            let apiKey: String?
            if record.kind.hasProviderAdapter, let ref = record.apiKeyRef {
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
            } else {
                // Buildable kind, but the factory still returned nil: either an
                // `.appleFoundation` row on an AFM-ineligible device (the
                // expected silent path) or a network kind with a nil `baseURL`
                // (a corrupt/synced row). Debug-level keeps the common AFM case
                // quiet while still making a bad row diagnosable in the field —
                // restoring what the pre-factory per-arm code surfaced.
                bootstrapLog.debug("Skipped buildable model row \(record.id, privacy: .public) kind \(record.kind.rawValue, privacy: .public) — provider construction returned nil (AFM unavailable or missing baseURL)")
            }
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
    /// DEBUG-only first-launch seed: insert the three `kind = .debug`
    /// `ModelConfigurationRecord`s — canned stream, annotate, and note — so
    /// the debug providers show up in the model picker without the user
    /// adding a model manually. Each row's existence check and insert run in
    /// a single GRDB write transaction (via `insertDebugRowIfMissing`), keyed
    /// on the row `id`, so two concurrent `bootstrap()` calls — vanishingly
    /// rare but trivial to close — can't both pass the check and double-insert.
    /// Only the canned-stream row is `selectable`: its `shouldSelect` is
    /// computed inside the transaction so it claims selection only when no
    /// other selection exists; the annotate/note rows are always inserted
    /// unselected (alternatives in the picker). A developer who has already
    /// wired a real provider keeps that active and sees the debug entries as
    /// alternatives.
    /// - Parameter includesTodoTool: Whether the `todo.create` tool is
    ///   registered in this build (i.e. the Todo applet is injected). Only
    ///   then is the "Debug (todo)" row seeded — SuperBible, which ships no
    ///   Todo applet, passes `false` so the row never appears in its picker
    ///   (where the tool call would fail).
    static func seedDebugModelIfNeeded(
        repository: GRDBModelConfigurationRepository,
        includesTodoTool: Bool = false
    ) async throws {
        // Canned-stream provider — the auto-selected default on a fresh
        // install (when nothing else is wired).
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
        // Annotate / note debug providers — alternatives in the picker that
        // emit canned `bible.annotate` / `bible.note` tool calls. Never the
        // auto-selected default (`selectable: false`); the user picks them to
        // exercise the Bible tool pipelines without a real model.
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
        // Read provider — emits a canned `bible.read` tool call from the
        // reference in the user's turn. Both targets register `bible.read`, so
        // it seeds unconditionally (unlike "Debug (todo)"). Never auto-selected.
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
        // Canned-stream provider wired to the client-mock search backend so
        // the full web-search flow (cost gate → confirm → sources pill →
        // Gemini suggestions on a "gemini" query) is exercisable in the
        // simulator with no key. Same `DebugLLMProvider` as "Debug (canned)";
        // the only difference is `searchBackend: "debug"`, which routes search
        // through `DebugWebSearchFulfiller`. Never auto-selected.
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
                // Literal mirrors `NativeWebSearch.mockBackendValue` (internal
                // to the Chat module, so unreachable here); a Chat unit test
                // pins the two equal.
                searchBackend: "debug"
            )
        }
        // Todo create provider — emits a canned `todo.create` tool call.
        // Gated on the Todo applet being injected (its tool registered): only
        // SuperOS ships Todo, so SuperBible passes `includesTodoTool: false`
        // and never seeds this row. Never auto-selected.
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
