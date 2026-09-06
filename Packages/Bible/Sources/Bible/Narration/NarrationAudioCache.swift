import Core
import CryptoKit
import Foundation
import GRDB

/// Cache boundary, injectable so playback tests do not write to the filesystem.
public protocol NarrationAudioCaching: Sendable {
    func audio(for key: String) async throws -> Data?
    func save(_ audio: Data, for key: String) async throws
    func remove(_ key: String) async throws
    func clear() async throws
    func byteCount() async throws -> Int
}

/// A bounded, disposable SQLite audio cache in the app's backup-excluded Caches directory.
public actor NarrationAudioCache: NarrationAudioCaching {
    private let queue: DatabaseQueue
    private let clock: any Clock
    private let limit: Int

    public init(queue: DatabaseQueue, clock: any Clock = SystemClock(), limit: Int = 100 * 1_024 * 1_024) throws {
        self.queue = queue
        self.clock = clock
        self.limit = limit
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_audio") { db in
            try db.execute(sql: "CREATE TABLE narrationAudio (id TEXT PRIMARY KEY NOT NULL, audio BLOB NOT NULL, byteCount INTEGER NOT NULL, accessedAt DATETIME NOT NULL)")
        }
        try migrator.migrate(queue)
    }

    public static func makeInMemory() throws -> NarrationAudioCache { try NarrationAudioCache(queue: DatabaseQueue()) }

    public static func open(in directory: URL) throws -> NarrationAudioCache {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let file = directory.appending(path: "narration-audio.sqlite")
        let cache = try NarrationAudioCache(queue: DatabaseQueue(path: file.path))
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        #endif
        return cache
    }

    public static func key(text: String, voice: OpenAISpeechVoice) -> String {
        let input = [OpenAISpeechGenerator.model, OpenAISpeechGenerator.instruction, "mp3", voice.rawValue, text].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func audio(for key: String) async throws -> Data? {
        let now = clock.now()
        return try await queue.write { db in
            let audio = try Data.fetchOne(db, sql: "SELECT audio FROM narrationAudio WHERE id = ?", arguments: [key])
            if audio != nil { try db.execute(sql: "UPDATE narrationAudio SET accessedAt = ? WHERE id = ?", arguments: [now, key]) }
            return audio
        }
    }
    public func save(_ audio: Data, for key: String) async throws {
        guard audio.count <= limit else { return }
        let now = clock.now()
        let limit = limit
        try await queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO narrationAudio (id, audio, byteCount, accessedAt) VALUES (?, ?, ?, ?)", arguments: [key, audio, audio.count, now])
            while (try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM narrationAudio") ?? 0) > limit {
                try db.execute(sql: "DELETE FROM narrationAudio WHERE id = (SELECT id FROM narrationAudio ORDER BY accessedAt, id LIMIT 1)")
            }
        }
    }
    public func remove(_ key: String) async throws {
        try await queue.write { try $0.execute(sql: "DELETE FROM narrationAudio WHERE id = ?", arguments: [key]) }
    }
    public func clear() async throws {
        try await queue.write { try $0.execute(sql: "DELETE FROM narrationAudio") }
        try await queue.vacuum()
    }
    public func byteCount() async throws -> Int {
        try await queue.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM narrationAudio") ?? 0 }
    }
}
