import Core
import CryptoKit
import Darwin
import Foundation

/// Cache boundary, injectable so playback tests do not write to the filesystem.
public protocol NarrationAudioCaching: Sendable {
    func audio(for key: String) async throws -> Data?
    func save(_ audio: Data, for key: String) async throws
    func remove(_ key: String) async throws
    func clear() async throws
    func byteCount() async throws -> Int
}

/// Disposable cache failures never expose underlying filesystem paths to the player.
public enum NarrationAudioCacheError: Error, Sendable { case unavailable }

/// Synchronous storage operations let the cache actor keep admission and eviction atomic with its index.
protocol NarrationAudioFileStorage: Sendable {
    /// Remove interrupted writes before admitting clips or reporting a successful clear.
    func removeTemporaryFiles() throws
    func files() throws -> [NarrationAudioFile]
    func read(_ name: String) throws -> Data?
    /// A failed write must leave the previous complete clip intact.
    func write(_ audio: Data, named name: String, accessedAt: Date) throws
    func remove(_ name: String) throws
    func touch(_ name: String, at date: Date) throws
}

/// File metadata reconstructs the disposable index without a second database or manifest.
struct NarrationAudioFile: Sendable {
    let name: String
    let byteCount: Int
    let accessedAt: Date
}

/// Bounded audio clips stored atomically in Caches, with an equivalent in-memory fallback.
public actor NarrationAudioCache: NarrationAudioCaching {
    private struct Entry: Sendable {
        let byteCount: Int
        var accessedAt: Date
        let audio: Data?
    }

    private let storage: (any NarrationAudioFileStorage)?
    private let clock: any Clock
    private let limit: Int
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0

    private init(clock: any Clock, limit: Int) {
        self.storage = nil
        self.clock = clock
        self.limit = max(0, limit)
    }

    init(storage: any NarrationAudioFileStorage, clock: any Clock = SystemClock(), limit: Int = 100 * 1_024 * 1_024) throws {
        self.storage = storage
        self.clock = clock
        self.limit = max(0, limit)
        do {
            try storage.removeTemporaryFiles()
            var loaded: [String: Entry] = [:]
            for file in try storage.files() where Self.owns(file.name) && file.byteCount >= 0 {
                loaded[file.name] = Entry(byteCount: file.byteCount, accessedAt: file.accessedAt, audio: nil)
            }
            var bytes = loaded.values.reduce(0) { $0 + $1.byteCount }
            try Self.evict(entries: &loaded, totalBytes: &bytes, storage: storage, target: max(0, limit))
            self.entries = loaded
            self.totalBytes = bytes
        } catch { throw NarrationAudioCacheError.unavailable }
    }

    public static func makeInMemory(clock: any Clock = SystemClock(), limit: Int = 100 * 1_024 * 1_024) throws -> NarrationAudioCache {
        NarrationAudioCache(clock: clock, limit: limit)
    }

    /// Optional disk caching must not prevent launch when directory lookup or opening fails.
    public static func openOrInMemory(
        directory: @Sendable () throws -> URL = {
            try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "OpenAINarration")
        },
        open: @Sendable (URL) throws -> NarrationAudioCache = { try NarrationAudioCache.open(in: $0) }
    ) throws -> NarrationAudioCache {
        do { return try open(directory()) } catch { return try makeInMemory() }
    }

    public static func open(in directory: URL, clock: any Clock = SystemClock(), limit: Int = 100 * 1_024 * 1_024) throws -> NarrationAudioCache {
        do {
            return try NarrationAudioCache(storage: FileNarrationAudioStorage(directory: directory), clock: clock, limit: limit)
        } catch { throw NarrationAudioCacheError.unavailable }
    }

    public static func key(text: String, voice: OpenAISpeechVoice) -> String {
        let input = [OpenAISpeechGenerator.model, OpenAISpeechGenerator.instruction, "mp3", voice.rawValue, text].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func audio(for key: String) async throws -> Data? {
        let name = Self.fileName(for: key)
        guard var entry = entries[name] else { return nil }
        let audio: Data?
        do { audio = try storage?.read(name) ?? entry.audio } catch { throw NarrationAudioCacheError.unavailable }
        guard let audio else {
            entries[name] = nil
            totalBytes -= entry.byteCount
            return nil
        }
        entry.accessedAt = clock.now()
        entries[name] = entry
        // Recency metadata is best-effort: failure must not discard already readable, paid audio.
        try? storage?.touch(name, at: entry.accessedAt)
        return audio
    }

    public func save(_ audio: Data, for key: String) async throws {
        guard audio.count <= limit else { return }
        let name = Self.fileName(for: key)
        let previousSize = entries[name]?.byteCount ?? 0
        let now = clock.now()
        do {
            // Evict before admission so a failed deletion cannot let the directory exceed its bound.
            try Self.evict(entries: &entries, totalBytes: &totalBytes, storage: storage,
                           target: limit - audio.count + previousSize, excluding: name)
            try storage?.write(audio, named: name, accessedAt: now)
        } catch { throw NarrationAudioCacheError.unavailable }
        entries[name] = Entry(byteCount: audio.count, accessedAt: now, audio: storage == nil ? audio : nil)
        totalBytes += audio.count - previousSize
    }

    public func remove(_ key: String) async throws {
        do { try removeFile(Self.fileName(for: key)) } catch { throw NarrationAudioCacheError.unavailable }
    }

    public func clear() async throws {
        do {
            try storage?.removeTemporaryFiles()
            for name in entries.keys.sorted() { try removeFile(name) }
        } catch { throw NarrationAudioCacheError.unavailable }
    }

    public func byteCount() async throws -> Int { totalBytes }

    private func removeFile(_ name: String) throws {
        guard let entry = entries[name] else { return }
        try storage?.remove(name)
        entries[name] = nil
        totalBytes -= entry.byteCount
    }

    private static func evict(
        entries: inout [String: Entry], totalBytes: inout Int, storage: (any NarrationAudioFileStorage)?,
        target: Int, excluding: String? = nil
    ) throws {
        while totalBytes > target {
            let candidate = entries.filter { $0.key != excluding }.min {
                $0.value.accessedAt == $1.value.accessedAt ? $0.key < $1.key : $0.value.accessedAt < $1.value.accessedAt
            }
            guard let (name, entry) = candidate else { throw NarrationAudioCacheError.unavailable }
            try storage?.remove(name)
            entries[name] = nil
            totalBytes -= entry.byteCount
        }
    }

    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".mp3"
    }

    fileprivate static func owns(_ name: String) -> Bool {
        name.count == 68 && name.hasSuffix(".mp3") && name.prefix(64).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

/// Stores only regular clip files in a dedicated directory; legacy experimental caches stay untouched.
private struct FileNarrationAudioStorage: NarrationAudioFileStorage {
    let directory: URL
    private let ids: any IDGenerator = UUIDGenerator()

    init(directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        self.directory = directory.appending(path: "clips", directoryHint: .isDirectory)
        try manager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func removeTemporaryFiles() throws {
        let manager = FileManager.default
        let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for url in urls {
            let name = url.lastPathComponent
            // UUIDGenerator emits canonical uppercase UUIDs. Other temporary files are not ours.
            guard name.count == 41, name.hasPrefix("."), name.hasSuffix(".tmp") else { continue }
            let identifier = String(name.dropFirst().dropLast(4))
            guard let uuid = UUID(uuidString: identifier), uuid.uuidString == identifier else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try manager.removeItem(at: url)
        }
    }

    func files() throws -> [NarrationAudioFile] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        ).compactMap { url in
            guard NarrationAudioCache.owns(url.lastPathComponent) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, let date = values.contentModificationDate else { return nil }
            return NarrationAudioFile(name: url.lastPathComponent, byteCount: size, accessedAt: date)
        }
    }

    func read(_ name: String) throws -> Data? {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NarrationAudioCacheError.unavailable }
        return try Data(contentsOf: url)
    }

    func write(_ audio: Data, named name: String, accessedAt: Date) throws {
        let temporary = directory.appending(path: ".\(ids.nextID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try audio.write(to: temporary, options: .completeFileProtection)
        #else
        try audio.write(to: temporary)
        #endif
        try FileManager.default.setAttributes([.modificationDate: accessedAt], ofItemAtPath: temporary.path)
        // The protected, complete temporary file replaces the old inode in one operation.
        guard rename(temporary.path, directory.appending(path: name).path) == 0 else {
            throw NarrationAudioCacheError.unavailable
        }
    }

    func remove(_ name: String) throws {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func touch(_ name: String, at date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.appending(path: name).path)
    }
}
