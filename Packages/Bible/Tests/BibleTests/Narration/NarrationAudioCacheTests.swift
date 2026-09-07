import Core
import Foundation
import Testing
import os
@testable import Bible

/// Disposable narration clips remain independent of Bible's single user-state database.
@Suite("Narration audio cache")
struct NarrationAudioCacheTests {
    @Test func cacheCreatesOnlyAudioFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try NarrationAudioCache.open(in: directory)
        try await cache.save(Data([1, 2, 3]), for: "verse")
        let rootFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(rootFiles == ["clips"])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "clips").path)
        #expect(files.count == 1)
        #expect(files.allSatisfy { $0.hasSuffix(".mp3") })
    }

    @Test func fileCacheReopensAndPreservesLeastRecentlyUsedOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FixedClock()
        let cache = try NarrationAudioCache.open(in: directory, clock: clock, limit: 4)
        try await cache.save(Data([1, 2]), for: "a")
        clock.advance(by: 1)
        try await cache.save(Data([3, 4]), for: "b")
        clock.advance(by: 1)
        #expect(try await cache.audio(for: "a") == Data([1, 2]))
        let reopened = try NarrationAudioCache.open(in: directory, clock: clock, limit: 4)
        clock.advance(by: 1)
        try await reopened.save(Data([5, 6]), for: "c")
        #expect(try await reopened.audio(for: "a") == Data([1, 2]))
        #expect(try await reopened.audio(for: "b") == nil)
        #expect(try await reopened.audio(for: "c") == Data([5, 6]))
        #expect(try await reopened.byteCount() == 4)
    }

    @Test func replacementAndOversizedAdmissionStayBounded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try NarrationAudioCache.open(in: directory, limit: 4)
        try await cache.save(Data([1, 2]), for: "a")
        try await cache.save(Data([3, 4]), for: "b")
        try await cache.save(Data(repeating: 9, count: 5), for: "a")
        #expect(try await cache.audio(for: "a") == Data([1, 2]))
        #expect(try await cache.byteCount() == 4)
        try await cache.save(Data([5, 6, 7]), for: "a")
        #expect(try await cache.audio(for: "b") == nil)
        #expect(try await cache.byteCount() == 3)
        try await cache.save(Data([8]), for: "a")
        let reopened = try NarrationAudioCache.open(in: directory, limit: 4)
        #expect(try await reopened.audio(for: "a") == Data([8]))
        #expect(try await reopened.byteCount() == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "clips").path)
        #expect(files.count == 1)
        #expect(files.allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func reopeningWithSmallerLimitEvictsOldestFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FixedClock()
        let cache = try NarrationAudioCache.open(in: directory, clock: clock, limit: 6)
        for key in ["a", "b", "c"] {
            try await cache.save(Data([1, 2]), for: key)
            clock.advance(by: 1)
        }
        let reopened = try NarrationAudioCache.open(in: directory, clock: clock, limit: 3)
        #expect(try await reopened.audio(for: "a") == nil)
        #expect(try await reopened.audio(for: "b") == nil)
        #expect(try await reopened.audio(for: "c") == Data([1, 2]))
        #expect(try await reopened.byteCount() == 2)
    }

    @Test func recencyTiesUseStableFileNameOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FixedClock()
        let cache = try NarrationAudioCache.open(in: directory, clock: clock, limit: 4)
        try await cache.save(Data([1, 2]), for: "a")
        try await cache.save(Data([3, 4]), for: "b")
        let clips = directory.appending(path: "clips")
        let firstName = try #require(FileManager.default.contentsOfDirectory(atPath: clips.path).min())
        clock.advance(by: 1)
        try await cache.save(Data([5, 6]), for: "c")
        #expect(!FileManager.default.fileExists(atPath: clips.appending(path: firstName).path))
        #expect(try await cache.byteCount() == 4)
    }

    @Test func reopeningAndClearingOnlyOwnsRegularAudioFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appending(path: "narration-audio.sqlite")
        try Data("unshipped legacy cache".utf8).write(to: legacy)
        let cache = try NarrationAudioCache.open(in: directory)
        try await cache.save(Data([1, 2, 3]), for: "../../outside")
        let clips = directory.appending(path: "clips")
        let note = clips.appending(path: "notes.txt")
        try Data([4]).write(to: note)
        let unfinished = clips.appending(path: ".unfinished.tmp")
        try Data([5]).write(to: unfinished)
        let nested = clips.appending(path: String(repeating: "a", count: 64) + ".mp3")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let link = clips.appending(path: String(repeating: "b", count: 64) + ".mp3")
        try manager.createSymbolicLink(at: link, withDestinationURL: legacy)
        let reopened = try NarrationAudioCache.open(in: directory)
        #expect(try await reopened.byteCount() == 3)
        #expect(try await reopened.audio(for: "../../outside") == Data([1, 2, 3]))
        try await reopened.clear()
        #expect(try await reopened.byteCount() == 0)
        #expect(try await reopened.audio(for: "../../outside") == nil)
        #expect(try Data(contentsOf: legacy) == Data("unshipped legacy cache".utf8))
        #expect(Set(try manager.contentsOfDirectory(atPath: clips.path)) == Set([note, unfinished, nested, link].map(\.lastPathComponent)))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func removedClipStaysAbsentAfterReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try NarrationAudioCache.open(in: directory)
        try await cache.save(Data([1, 2, 3]), for: "invalid")
        try await cache.remove("invalid")
        let reopened = try NarrationAudioCache.open(in: directory)
        #expect(try await reopened.byteCount() == 0)
        #expect(try await reopened.audio(for: "invalid") == nil)
    }

    @Test func externallyRemovedClipBecomesAMiss() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try NarrationAudioCache.open(in: directory)
        try await cache.save(Data([1, 2, 3]), for: "evicted-by-system")
        let clips = directory.appending(path: "clips")
        let file = try #require(FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: file)
        #expect(try await cache.audio(for: "evicted-by-system") == nil)
        #expect(try await cache.byteCount() == 0)
    }

    @Test func failedWritePreservesReplacementAndAccounting() async throws {
        let storage = FaultingNarrationAudioStorage()
        let cache = try NarrationAudioCache(storage: storage, limit: 4)
        try await cache.save(Data([1, 2]), for: "a")
        storage.failWrites()
        await #expect(throws: NarrationAudioCacheError.unavailable) { try await cache.save(Data([3, 4, 5]), for: "a") }
        await #expect(throws: NarrationAudioCacheError.unavailable) { try await cache.save(Data([6]), for: "b") }
        #expect(try await cache.audio(for: "a") == Data([1, 2]))
        #expect(try await cache.audio(for: "b") == nil)
        #expect(try await cache.byteCount() == 2)
        #expect(storage.writtenBytes == 2)
    }

    @Test func failedEvictionAbortsAdmissionWithoutLosingAccounting() async throws {
        let storage = FaultingNarrationAudioStorage()
        let clock = FixedClock()
        let cache = try NarrationAudioCache(storage: storage, clock: clock, limit: 6)
        for key in ["a", "b", "c"] {
            try await cache.save(Data([1, 2]), for: key)
            clock.advance(by: 1)
        }
        storage.failRemoval(after: 1)
        await #expect(throws: NarrationAudioCacheError.unavailable) { try await cache.save(Data([3, 4, 5, 6]), for: "d") }
        #expect(try await cache.audio(for: "a") == nil)
        #expect(try await cache.audio(for: "b") == Data([1, 2]))
        #expect(try await cache.audio(for: "d") == nil)
        #expect(try await cache.byteCount() == 4)
        #expect(storage.writtenBytes == 4)
    }

    @Test func failedRemoveAndClearKeepRemainingFilesAccounted() async throws {
        let storage = FaultingNarrationAudioStorage()
        let cache = try NarrationAudioCache(storage: storage)
        try await cache.save(Data([1, 2]), for: "a")
        try await cache.save(Data([3, 4]), for: "b")
        storage.failRemoval(after: 0)
        await #expect(throws: NarrationAudioCacheError.unavailable) { try await cache.remove("a") }
        #expect(try await cache.byteCount() == 4)
        storage.failRemoval(after: 1)
        await #expect(throws: NarrationAudioCacheError.unavailable) { try await cache.clear() }
        #expect(try await cache.byteCount() == 2)
        #expect(storage.writtenBytes == 2)
        storage.failRemoval(after: nil)
        try await cache.clear()
        #expect(try await cache.byteCount() == 0)
        #expect(storage.writtenBytes == 0)
    }

    @Test func failedTouchStillReturnsAudioAndUpdatesInMemoryRecency() async throws {
        let storage = FaultingNarrationAudioStorage()
        let clock = FixedClock()
        let cache = try NarrationAudioCache(storage: storage, clock: clock, limit: 4)
        try await cache.save(Data([1, 2]), for: "a")
        clock.advance(by: 1)
        try await cache.save(Data([3, 4]), for: "b")
        storage.failTouches()
        clock.advance(by: 1)
        #expect(try await cache.audio(for: "a") == Data([1, 2]))
        clock.advance(by: 1)
        try await cache.save(Data([5, 6]), for: "c")
        #expect(try await cache.audio(for: "a") == Data([1, 2]))
        #expect(try await cache.audio(for: "b") == nil)
        #expect(try await cache.byteCount() == 4)
    }

    @Test func failedReadKeepsAccountingAndCanRecover() async throws {
        let storage = FaultingNarrationAudioStorage()
        let cache = try NarrationAudioCache(storage: storage)
        try await cache.save(Data([1, 2]), for: "a")
        storage.failReads(true)
        await #expect(throws: NarrationAudioCacheError.unavailable) { _ = try await cache.audio(for: "a") }
        #expect(try await cache.byteCount() == 2)
        storage.failReads(false)
        #expect(try await cache.audio(for: "a") == Data([1, 2]))
    }

    @Test func failedStartupEvictionFallsBackToMemory() async throws {
        let storage = FaultingNarrationAudioStorage()
        let cache = try NarrationAudioCache(storage: storage, limit: 4)
        try await cache.save(Data([1, 2]), for: "a")
        try await cache.save(Data([3, 4]), for: "b")
        storage.failRemoval(after: 0)
        let fallback = try NarrationAudioCache.openOrInMemory(
            directory: { URL(fileURLWithPath: "/unused") },
            open: { _ in try NarrationAudioCache(storage: storage, limit: 2) }
        )
        #expect(try await fallback.byteCount() == 0)
        try await fallback.save(Data([5, 6]), for: "c")
        #expect(try await fallback.audio(for: "c") == Data([5, 6]))
        #expect(storage.writtenBytes == 4)
    }

    #if os(iOS)
    @Test func atomicReplacementRetainsCompleteFileProtection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try NarrationAudioCache.open(in: directory)
        for audio in [Data([1, 2]), Data([3, 4, 5])] {
            try await cache.save(audio, for: "protected")
            let clips = directory.appending(path: "clips")
            let file = try #require(FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil).first)
            #if !targetEnvironment(simulator)
            // Simulator filesystems do not expose iOS Data Protection attributes.
            // Verify the protection class on physical iOS; all iOS runs verify replacement bytes.
            let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
            #expect(protection == .complete)
            #endif
            #expect(try Data(contentsOf: file) == audio)
        }
    }
    #endif

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }
}

/// Synchronous fault injection models the atomic-write contract without performing filesystem I/O.
private final class FaultingNarrationAudioStorage: NarrationAudioFileStorage {
    private struct StoredFile {
        let audio: Data
        var date: Date
    }
    private struct State {
        var files: [String: StoredFile] = [:]
        var rejectsWrites = false
        var rejectsTouches = false
        var rejectsReads = false
        var successfulRemovalsBeforeFailure: Int?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var writtenBytes: Int { state.withLock { $0.files.values.reduce(0) { $0 + $1.audio.count } } }
    func failWrites() { state.withLock { $0.rejectsWrites = true } }
    func failTouches() { state.withLock { $0.rejectsTouches = true } }
    func failReads(_ fails: Bool) { state.withLock { $0.rejectsReads = fails } }
    func failRemoval(after successfulRemovals: Int?) { state.withLock { $0.successfulRemovalsBeforeFailure = successfulRemovals } }
    func files() throws -> [NarrationAudioFile] {
        state.withLock { state in
            state.files.map { NarrationAudioFile(name: $0.key, byteCount: $0.value.audio.count, accessedAt: $0.value.date) }
        }
    }
    func read(_ name: String) throws -> Data? {
        try state.withLock { state in
            guard !state.rejectsReads else { throw NarrationAudioCacheError.unavailable }
            return state.files[name]?.audio
        }
    }
    func write(_ audio: Data, named name: String, accessedAt: Date) throws {
        try state.withLock { state in
            guard !state.rejectsWrites else { throw NarrationAudioCacheError.unavailable }
            state.files[name] = StoredFile(audio: audio, date: accessedAt)
        }
    }
    func remove(_ name: String) throws {
        try state.withLock { state in
            if let remaining = state.successfulRemovalsBeforeFailure {
                guard remaining > 0 else { throw NarrationAudioCacheError.unavailable }
                state.successfulRemovalsBeforeFailure = remaining - 1
            }
            state.files[name] = nil
        }
    }
    func touch(_ name: String, at date: Date) throws {
        try state.withLock { state in
            guard !state.rejectsTouches else { throw NarrationAudioCacheError.unavailable }
            state.files[name]?.date = date
        }
    }
}
