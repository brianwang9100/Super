import Foundation
@testable import Bible

/// A deterministic reading-position repository whose reads and selected writes
/// can be suspended until a test explicitly releases them.
actor GatedBibleReadingPositionRepository: BibleReadingPositionRepository {
    enum Failure: Error {
        case load
        case save
    }

    enum LoadResult: Sendable {
        case success(BibleReadingPositionRecord?)
        case failure
    }

    enum SaveResult: Sendable {
        case success
        case failure
    }

    private var storedRecord: BibleReadingPositionRecord?
    private var pendingLoads: [CheckedContinuation<LoadResult, Never>] = []
    private var loadArrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var saveArrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var suspendedSave: CheckedContinuation<Void, Never>?
    private var suspendNextSaveFlag = false
    private var nextSaveResults: [SaveResult] = []

    private(set) var loadCallCount = 0
    private(set) var saveAttempts: [BibleReadingPositionRecord] = []

    init(record: BibleReadingPositionRecord? = nil) {
        storedRecord = record
    }

    func load() async throws -> BibleReadingPositionRecord? {
        loadCallCount += 1
        resumeLoadWaitersIfReady()
        let result = await withCheckedContinuation { continuation in
            pendingLoads.append(continuation)
        }
        switch result {
        case .success(let record):
            storedRecord = record
            return record
        case .failure:
            throw Failure.load
        }
    }

    func save(_ record: BibleReadingPositionRecord) async throws {
        saveAttempts.append(record)
        resumeSaveWaitersIfReady()
        if suspendNextSaveFlag {
            suspendNextSaveFlag = false
            await withCheckedContinuation { continuation in
                suspendedSave = continuation
            }
        }
        let result = nextSaveResults.isEmpty ? SaveResult.success : nextSaveResults.removeFirst()
        switch result {
        case .success:
            storedRecord = record
        case .failure:
            throw Failure.save
        }
    }

    func waitForLoadCall(count: Int) async {
        guard loadCallCount < count else { return }
        await withCheckedContinuation { continuation in
            loadArrivalWaiters.append((count, continuation))
        }
    }

    func releaseNextLoad(_ result: LoadResult) {
        guard !pendingLoads.isEmpty else {
            fatalError("releaseNextLoad called without a pending load")
        }
        pendingLoads.removeFirst().resume(returning: result)
    }

    func suspendNextSave() {
        suspendNextSaveFlag = true
    }

    func waitForSaveAttempt(count: Int) async {
        guard saveAttempts.count < count else { return }
        await withCheckedContinuation { continuation in
            saveArrivalWaiters.append((count, continuation))
        }
    }

    func releaseSuspendedSave() {
        guard let suspendedSave else {
            fatalError("releaseSuspendedSave called without a suspended save")
        }
        self.suspendedSave = nil
        suspendedSave.resume()
    }

    func enqueueSaveResult(_ result: SaveResult) {
        nextSaveResults.append(result)
    }

    func currentRecord() -> BibleReadingPositionRecord? {
        storedRecord
    }

    private func resumeLoadWaitersIfReady() {
        let ready = loadArrivalWaiters.filter { loadCallCount >= $0.count }
        loadArrivalWaiters.removeAll { loadCallCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func resumeSaveWaitersIfReady() {
        let ready = saveArrivalWaiters.filter { saveAttempts.count >= $0.count }
        saveArrivalWaiters.removeAll { saveAttempts.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
