import AVFoundation
import Core
import Foundation

/// Playback signals are separate from download completion and drive verse highlighting.
public enum NarrationAudioEvent: Sendable { case started, finished, failed }

/// Injectable native audio playback with synchronous transport control on the main actor.
@MainActor public protocol NarrationAudioPlaying: AnyObject {
    func play(_ audio: Data, rate: Float) -> AsyncStream<NarrationAudioEvent>
    func pause()
    func resume()
    func stop()
    func setRate(_ rate: Float)
}

/// MP3 playback backed by Apple's audio player; delegates bridge into one asynchronous event stream.
@MainActor public final class NarrationAudioPlayer: NSObject, NarrationAudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: AsyncStream<NarrationAudioEvent>.Continuation?
    #if os(iOS)
    private var previousSession: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    private var interruptionTask: Task<Void, Never>?
    #endif

    public override init() { super.init() }

    public func play(_ audio: Data, rate: Float) -> AsyncStream<NarrationAudioEvent> {
        stop()
        let (stream, continuation) = AsyncStream<NarrationAudioEvent>.makeStream()
        self.continuation = continuation
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            previousSession = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            interruptionTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                    guard let self, !Task.isCancelled else { return }
                    self.continuation?.yield(.failed)
                    self.stop()
                    return
                }
            }
            #endif
            let player = try AVAudioPlayer(data: audio)
            self.player = player
            player.delegate = self
            player.enableRate = true
            player.rate = min(2, max(0.75, rate))
            guard player.prepareToPlay(), player.play() else { throw SpeechGenerationError.invalidAudio }
            continuation.yield(.started)
        } catch {
            continuation.yield(.failed)
            stop()
        }
        return stream
    }
    public func pause() { player?.pause() }
    public func resume() { player?.play() }
    public func setRate(_ rate: Float) { player?.rate = min(2, max(0.75, rate)) }
    public func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        continuation?.finish()
        continuation = nil
        #if os(iOS)
        interruptionTask?.cancel()
        interruptionTask = nil
        if let previous = previousSession {
            previousSession = nil
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.category, mode: previous.mode, options: previous.options)
        }
        #endif
    }
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == id else { return }
            self.continuation?.yield(flag ? .finished : .failed)
            self.stop()
        }
    }
    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
