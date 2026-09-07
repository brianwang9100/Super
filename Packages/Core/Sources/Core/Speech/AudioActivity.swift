import Observation

/// Coordinates foreground playback with microphone capture at the composition root.
@MainActor @Observable
public final class AudioActivity {
    public private(set) var isCapturing = false
    public var stopPlayback: (() -> Void)?
    public init() {}
    public func beginCapture() {
        isCapturing = true
        stopPlayback?()
    }
    public func endCapture() { isCapturing = false }
}
