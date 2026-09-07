#if DEBUG
import SwiftUI

/// A fixed phase of the recording ring, used only by deterministic preview fixtures.
struct ChatComposerPreviewPulse: Equatable, Sendable {
    let progress: Double

    init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    var scale: Double { 1 + 0.5 * progress }
    var opacity: Double { 0.6 * (1 - progress) }

    static func shouldAnimate(reduceMotion: Bool, override: Self?) -> Bool {
        !reduceMotion && override == nil
    }
}

/// Nil preserves the production animation path, including existing snapshot tests.
private struct ChatComposerPreviewPulseKey: EnvironmentKey {
    static let defaultValue: ChatComposerPreviewPulse? = nil
}

extension EnvironmentValues {
    var chatComposerPreviewPulse: ChatComposerPreviewPulse? {
        get { self[ChatComposerPreviewPulseKey.self] }
        set { self[ChatComposerPreviewPulseKey.self] = newValue }
    }
}
#endif
