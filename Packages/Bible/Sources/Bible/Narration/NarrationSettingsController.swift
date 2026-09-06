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
    private var credentialTask: Task<Void, Never>?

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
        return ProviderAudioCredential(id: id, name: record.sourceName ?? "OpenAI key", keyRef: ref)
    }
    public var snapshot: ProviderAudioSnapshot {
        ProviderAudioSnapshot(enabled: record.enabled, source: source, revision: record.revision)
    }
    public var providerSetup: ProviderAudioSetup {
        ProviderAudioSetup(snapshot: { self.snapshot }) { credential, enabled, useThisKey, revision in
            try await self.configure(credential: credential, enabled: enabled, useThisKey: useThisKey, expecting: revision)
        }
    }

    public func load() async {
        do {
            if let saved = try await repository.load() { record = saved }
            await refreshCredentials()
            await cleanRetiredKeys()
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
        sources = await listSources()
        let old = hasKey
        if let ref = record.keyRef,
           record.ownsKey || sources.contains(where: { $0.id == record.sourceId && $0.keyRef == ref }) {
            hasKey = ((try? await keychain.getString(ref: ref))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        } else { hasKey = false }
        if old && !hasKey { onInvalidated?() }
        onChange?()
    }

    /// Resolves the current source before every request. A model deletion cannot leave a captured key usable.
    public func apiKey() async throws -> String {
        guard record.enabled == true, let ref = record.keyRef else { throw SpeechGenerationError.missingKey }
        let revision = record.revision
        if !record.ownsKey {
            let current = await listSources()
            guard current.contains(where: { $0.id == record.sourceId && $0.keyRef == ref }) else {
                throw SpeechGenerationError.missingKey
            }
        }
        let key = try await keychain.getString(ref: ref)
        guard revision == record.revision, record.enabled == true,
              let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechGenerationError.missingKey
        }
        return key
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
        if enabled {
            guard let ref = next.keyRef,
                  let key = try await keychain.getString(ref: ref),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NarrationSettingsError.missingCredential
            }
            if record.enabled == nil { next.preferredVoiceId = NarrationVoice.marin.id }
        }
        if record.ownsKey, next.keyRef != record.keyRef, let ref = record.keyRef {
            next.retiredKeyRefs.append(ref)
        }
        try await persist(next, expecting: revision, invalidate: true)
        await cleanRetiredKeys()
    }

    public func saveDedicatedKey(_ key: String, enabled: Bool, expecting revision: Int) async throws {
        guard !isSaving, revision == record.revision else { throw NarrationSettingsError.staleDraft }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NarrationSettingsError.missingCredential }
        let ref = ids.nextID()
        do { try await keychain.setString(trimmed, ref: ref) } catch { throw NarrationSettingsError.secureStorage }
        var next = record
        if record.ownsKey, let old = record.keyRef { next.retiredKeyRefs.append(old) }
        next.sourceId = ref
        next.sourceName = "Narration-only OpenAI key"
        next.keyRef = ref
        next.ownsKey = true
        next.enabled = enabled
        if enabled, record.enabled == nil { next.preferredVoiceId = NarrationVoice.marin.id }
        do {
            try await persist(next, expecting: revision, invalidate: true)
        } catch {
            // Only this freshly created, narration-owned key is eligible for rollback.
            try await keychain.delete(ref: ref)
            throw error
        }
        await cleanRetiredKeys()
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard !enabled || hasKey else { throw NarrationSettingsError.missingCredential }
        var next = record
        next.enabled = enabled
        if enabled, record.enabled == nil { next.preferredVoiceId = NarrationVoice.marin.id }
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
        var next = value
        next.revision = revision + 1
        next.updatedAt = clock.now()
        try await repository.save(next, expecting: revision)
        if invalidate { onInvalidated?() }
        record = next
        await refreshCredentials()
    }

    private func cleanRetiredKeys() async {
        guard !record.retiredKeyRefs.isEmpty else { return }
        do {
            for ref in record.retiredKeyRefs { try await keychain.delete(ref: ref) }
            var next = record
            next.retiredKeyRefs = []
            try await persist(next, expecting: record.revision, invalidate: false)
        } catch { errorMessage = "An old narration key could not be removed. Reopen Narration settings to retry." }
    }
}
