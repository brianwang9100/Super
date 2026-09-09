import Core
import SwiftUI

struct SuperOSContentView: View {
    let state: SuperOSBootstrapState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .loading:
                // Pin Light: matches the Info.plist SplashBackground colorset.
                SplashView()
                    .superTheme(.make(.vellumLight))
                    .transition(.opacity)
            case .failed(let message):
                FailureScreen(message: message)
                    .transition(.opacity)
            case .ready(let dependencies):
                AppShell(dependencies: dependencies.shellDependencies)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: state.discriminant
        )
    }
}

// MARK: - Previews

#Preview("loading") {
    SuperOSContentView(state: .loading)
}

#Preview("failed") {
    SuperOSContentView(state: .failed("could not open chat.sqlite"))
}
