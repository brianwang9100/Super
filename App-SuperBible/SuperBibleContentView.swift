import Chat
import Core
import SwiftUI

/// Match the system launch image and background through the first SwiftUI frame.
/// Center in the full window: centering only an overlay that ignores safe areas
/// shifts the mark during the system launch-screen cross-fade.
struct SuperBibleContentView: View {
    let state: SuperBibleBootstrapState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .loading:
                GeometryReader { geo in
                    Color("SplashBackground")
                        .overlay {
                            Image("LaunchImage")
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            case .failed(let message):
                FailureScreen(message: message)
                    .transition(.opacity)
            case .ready(let dependencies):
                AppShell(dependencies: dependencies.shellDependencies)
                    .environment(\.appletSettingsContributions, dependencies.appletSettingsContributions)
                    .chatEmptyStateGlyph(.star)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: state.discriminant
        )
    }
}
