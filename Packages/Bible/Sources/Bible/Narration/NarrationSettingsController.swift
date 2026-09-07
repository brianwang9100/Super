import Core
import Foundation
import Observation

/// Owns narration setup drafts and runtime Keychain availability alongside persisted preferences.
@MainActor @Observable
public final class NarrationSettingsController {
    public private(set) var record: NarrationSettingsRecord
    public private(set) var hasKey = false
    public private(set) var appleEnhancedVoicesAvailable: Bool?
    public private(set) var isSaving = false
    public private(set) var sources: [ProviderAudioCredential] = []
    public var errorMessage: String?
    public var onChange: (() -> Void)?
    public var onInvalidated: (() -> Void)?
    private let repository: any NarrationSettingsRepository
    private let keychain: any KeychainClient
    private let clock: any Clock
    private let ids: any IDGenerator
    private let appleVoicesInstalled: @Sendable () async -> Bool
    private let listSources: @Sendable () async -> [ProviderAudioCredential]
    private var credentialRefreshGeneration = 0
    private var credentialTask: Task<Void, Never>?
    private static let stagedKeyCleanupMessage = "An unused narration key could not be removed. Restart the app or save again to retry cleanup."

    public init(
        repository: any NarrationSettingsRepository,
        keychain: any KeychainClient,
        listSources: @escaping @Sendable () async -> [ProviderAudioCredential],
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator(),
        appleVoicesInstalled: @escaping @Sendable () async -> Bool = {
            await Task.detached { AVSpeechSynthesizerNarrationService.installedVoice() != nil }.value
        }
    ) {
        self.appleVoicesInstalled = appleVoicesInstalled
        self.repository = repository
        self.keychain = keychain
        self.listSources = listSources
        self.clock = clock
        self.ids = ids
        self.record = NarrationSettingsRecord(id: ids.nextID(), updatedAt: clock.now())
    }

    public var openAIAvailable: Bool { record.enabled == true && hasKey }
    public var source: ProviderAudioCredential? {
        guard let id = record.sourceId, let ref = record.keyRef else { return nil }
        if !record.ownsKey, let current = sources.first(where: { $0.id == id }) { return current }
        // Preserve the last name/reference for missing-source UI only, never credential lookup.
        return ProviderAudioCredential(id: id, name: record.sourceName ?? "OpenAI key", keyRef: ref)
    }
    public var snapshot: ProviderAudioSnapshot {
        // Recovery labels may reference removed credentials; setup drafts need an available choice.
        ProviderAudioSnapshot(enabled: record.enabled, source: hasKey ? source : nil, revision: record.revision)
    }
    public var providerSetup: ProviderAudioSetup {
        ProviderAudioSetup(snapshot: { self.snapshot }) { credential, enabled, useThisKey, revision in
            try await self.configure(credential: credential, enabled: enabled, useThisKey: useThisKey, expecting: revision)
        }
    }

    public func load() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let saved = try await repository.load() { record = saved }
            await cleanStagedKeys()
            await refreshCredentials()
            await cleanRetiredKeysWhileSaving()
        } catch { errorMessage = "Narration settings could not be loaded. Try again." }
    }

    public func attach(to bus: SuperEventBus) async {
        credentialTask?.cancel()
        let events = await bus.events()
        credentialTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                if case .credentialChanged(let id) = event {
                    if id == record.sourceId { onInvalidated?() }
                    await refreshCredentials()
                }
            }
        }
        await load()
    }

    /// Rechecks device-installed voices after returning from Apple's download settings.
    public func refreshAppleVoices() async {
        appleEnhancedVoicesAvailable = await appleVoicesInstalled()
    }

    public func refreshCredentials() async {
        credentialRefreshGeneration += 1
        let generation = credentialRefreshGeneration
        let selected = record
        let currentSources = await listSources()
        let ref = selected.ownsKey ? selected.keyRef : currentSources.first(where: { $0.id == selected.sourceId })?.keyRef
        let available: Bool
        if let ref {
            available = ((try? await keychain.getString(ref: ref))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        } else { available = false }
        guard generation == credentialRefreshGeneration, selected.revision == record.revision else { return }
        let old = hasKey
        sources = currentSources
        hasKey = available
        if old && !hasKey { onInvalidated?() }
        onChange?()
    }

    /// Borrowers follow their selected model's committed key reference, never an in-progress replacement.
    public func apiKey() async throws -> String {
        let selected = record
        guard selected.enabled == true else { throw SpeechGenerationError.missingKey }
        let ref: String
        if selected.ownsKey {
            guard let ownedRef = selected.keyRef else { throw SpeechGenerationError.missingKey }
            ref = ownedRef
        } else {
            let current = await listSources()
            guard let committed = current.first(where: { $0.id == selected.sourceId }) else {
                throw SpeechGenerationError.missingKey
            }
            ref = committed.keyRef
        }
        guard hasSameCredential(as: selected) else { throw SpeechGenerationError.missingKey }
        let key = try await keychain.getString(ref: ref)
        if !selected.ownsKey {
            let current = await listSources()
            guard current.contains(where: { $0.id == selected.sourceId && $0.keyRef == ref }) else {
                throw SpeechGenerationError.missingKey
            }
        }
        guard hasSameCredential(as: selected), record.enabled == true,
              let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechGenerationError.missingKey
        }
        return key
    }

    private func hasSameCredential(as selected: NarrationSettingsRecord) -> Bool {
        // Preferences advance the draft revision without changing permission or credential identity.
        record.enabled == selected.enabled && record.sourceId == selected.sourceId
            && record.keyRef == selected.keyRef && record.ownsKey == selected.ownsKey
    }

    public func configure(
        credential: ProviderAudioCredential,
        enabled: Bool,
        useThisKey: Bool,
        expecting revision: Int
    ) async throws {
        guard revision == record.revision else { throw NarrationSettingsError.staleDraft }
        var next = record
        if useThisKey || source == nil {
            next.sourceId = credential.id
            next.sourceName = credential.name
            next.keyRef = credential.keyRef
            next.ownsKey = false
        }
        next.enabled = enabled
        if !next.ownsKey {
            let current = await listSources()
            if let committed = current.first(where: { $0.id == next.sourceId }) {
                next.keyRef = committed.keyRef
                next.sourceName = committed.name
            } else if enabled { throw NarrationSettingsError.missingCredential }
        }
        if enabled {
            guard let ref = next.keyRef,
                  let key = try await keychain.getString(ref: ref),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NarrationSettingsError.missingCredential
            }
            if record.preferredVoiceId == nil { next.preferredVoiceId = NarrationVoice.marin.id }
        }
        if record.ownsKey, next.keyRef != record.keyRef, let ref = record.keyRef {
            next.retiredKeyRefs.append(ref)
        }
        guard !isSaving, revision == record.revision else { throw NarrationSettingsError.staleDraft }
        var comparable = next
        comparable.sourceName = record.sourceName
        if comparable == record {
            // Model saves also commit their audio draft. A display-only rename must not
            // interrupt playback or invalidate an in-flight key read by advancing revision.
            await refreshCredentials()
            return
        }
        try await persist(next, expecting: revision, invalidate: true)
        await cleanRetiredKeys()
    }

    public func saveDedicatedKey(_ key: String, enabled: Bool, expecting revision: Int) async throws {
        guard !isSaving, revision == record.revision else { throw NarrationSettingsError.staleDraft }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NarrationSettingsError.missingCredential }
        isSaving = true
        defer { isSaving = false }
        await cleanStagedKeys()
        let ref = ids.nextID()
        // Register cleanup ownership before writing a secret; active settings and revision stay unchanged.
        do { try await repository.registerStagedKey(ref: ref) } catch { throw NarrationSettingsError.persistence }
        do {
            try await keychain.setString(trimmed, ref: ref)
        } catch {
            await cleanFailedStagedKey(ref: ref)
            throw NarrationSettingsError.secureStorage
        }
        var next = record
        if record.ownsKey, let old = record.keyRef { next.retiredKeyRefs.append(old) }
        next.sourceId = ref
        next.sourceName = "Narration-only OpenAI key"
        next.keyRef = ref
        next.ownsKey = true
        next.enabled = enabled
        if enabled, record.preferredVoiceId == nil { next.preferredVoiceId = NarrationVoice.marin.id }
        do {
            try await commitWhileSaving(next, expecting: revision, invalidate: true)
        } catch {
            // Failed rollback keeps its durable ledger row, and must not hide the original save failure.
            await cleanFailedStagedKey(ref: ref)
            throw error
        }
        await cleanRetiredKeysWhileSaving()
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard !enabled || hasKey else { throw NarrationSettingsError.missingCredential }
        var next = record
        next.enabled = enabled
        if enabled, record.preferredVoiceId == nil { next.preferredVoiceId = NarrationVoice.marin.id }
        try await persist(next, expecting: record.revision, invalidate: true)
    }

    public func removeDedicatedKey() async throws {
        guard record.ownsKey, let ref = record.keyRef else { return }
        var next = record
        next.enabled = false
        next.sourceId = nil
        next.sourceName = nil
        next.keyRef = nil
        next.ownsKey = false
        next.retiredKeyRefs.append(ref)
        try await persist(next, expecting: record.revision, invalidate: true)
        await cleanRetiredKeys()
    }

    /// Changes speed without promoting a temporary playback voice to the saved preference.
    public func setRate(_ rate: Float) async throws {
        var next = record
        next.rate = Double(rate)
        try await persist(next, expecting: record.revision, invalidate: false)
    }

    public func setPreference(voice: NarrationVoice?, rate: Float) async throws {
        var next = record
        next.preferredVoiceId = voice?.id
        if voice?.company == .apple { next.lastAppleVoiceId = voice?.id }
        next.rate = Double(rate)
        try await persist(next, expecting: record.revision, invalidate: false)
    }

    private func persist(_ value: NarrationSettingsRecord, expecting revision: Int, invalidate: Bool) async throws {
        guard !isSaving, revision == record.revision else { throw NarrationSettingsError.staleDraft }
        isSaving = true
        defer { isSaving = false }
        try await commitWhileSaving(value, expecting: revision, invalidate: invalidate)
    }

    private func commitWhileSaving(_ value: NarrationSettingsRecord, expecting revision: Int, invalidate: Bool) async throws {
        guard isSaving, revision == record.revision else { throw NarrationSettingsError.staleDraft }
        var next = value
        next.revision = revision + 1
        next.updatedAt = clock.now()
        try await repository.save(next, expecting: revision)
        if invalidate { onInvalidated?() }
        record = next
        await refreshCredentials()
    }

    private func cleanRetiredKeys() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        await cleanRetiredKeysWhileSaving()
    }

    private func cleanRetiredKeysWhileSaving() async {
        guard !record.retiredKeyRefs.isEmpty else { return }
        do {
            for ref in record.retiredKeyRefs { try await keychain.delete(ref: ref) }
            var next = record
            next.retiredKeyRefs = []
            try await commitWhileSaving(next, expecting: record.revision, invalidate: false)
        } catch { errorMessage = "An old narration key could not be removed. Reopen Narration settings to retry." }
    }

    private func cleanStagedKeys() async {
        do {
            for ref in try await repository.stagedKeyRefs() { try await discardStagedKey(ref: ref) }
            if errorMessage == Self.stagedKeyCleanupMessage { errorMessage = nil }
        } catch { errorMessage = Self.stagedKeyCleanupMessage }
    }

    private func cleanFailedStagedKey(ref: String) async {
        do { try await discardStagedKey(ref: ref) } catch { errorMessage = Self.stagedKeyCleanupMessage }
    }

    private func discardStagedKey(ref: String) async throws {
        // Recheck authoritative state even after a failed save: an active owned key is never cleanup work.
        let active = try await repository.load()
        if active?.ownsKey != true || active?.keyRef != ref { try await keychain.delete(ref: ref) }
        // A failed metadata deletion leaves the reference retryable, including when its secret is already gone.
        try await repository.removeStagedKey(ref: ref)
    }
}
